module Hecks
  module Bench
    # Runs every requested target against every requested domain and aggregates the runs.
    # Runs are interleaved across targets so unrelated machine load lands on all of them.
    module Suite
      TARGETS = %w[ruby:memory ruby:sqlite ruby:postgres ruby:postgres_era rust].freeze

      # What to measure; `rust_binary` needs a single domain, since a binary embeds exactly one.
      Config = Struct.new(:domains, :targets, :warmup, :iterations, :runs, :rust_binary, keyword_init: true)

      module_function

      def call(config, log: $stderr)
        validate(config)
        load_before = Environment.load_average
        skipped = unavailable_targets(config)
        active = config.targets - skipped.map { |entry| entry[:target] }
        skipped.each { |entry| log.puts "skip #{entry[:target]}: #{entry[:reason]}" }
        results = config.domains.flat_map { |domain| measure_domain(Workload.fetch(domain), active, config, log) }
        environment = Environment.describe
        environment[:load_average] = { before: load_before, after: environment[:load_average] }
        { environment: environment.merge(postgres: postgres_version(active)),
          config: config.to_h, results: results, skipped: skipped }
      end

      def validate(config)
        unknown = config.targets - TARGETS
        raise ArgumentError, "unknown target #{unknown.first.inspect} — one of #{TARGETS.join(', ')}" if unknown.any?

        config.domains.each { |domain| Workload.fetch(domain) }
        if config.iterations < 1 || config.runs < 1 || config.warmup.negative?
          raise ArgumentError, "iterations and runs must be at least 1, and warmup at least 0"
        end
        return unless config.rust_binary && config.domains.size > 1

        raise ArgumentError, "--rust-binary embeds one domain, so it needs exactly one --domain"
      end

      def unavailable_targets(config)
        postgres = PostgresProbe.unavailable_reason if config.targets.any? { |t| t.start_with?("ruby:postgres") }
        rust = RustRunner.unavailable_reason(binary: config.rust_binary) if config.targets.include?("rust")
        config.targets.filter_map do |target|
          reason = target == "rust" ? rust : (postgres if target.start_with?("ruby:postgres"))
          { target: target, reason: reason } if reason
        end
      end

      def measure_domain(workload, targets, config, log)
        binaries = {}
        summaries = Hash.new { |hash, target| hash[target] = [] }
        config.runs.times do |index|
          targets.each do |target|
            run = measure_once(workload, target, config, binaries)
            summaries[target] << run.summary
            log.puts progress_line("#{workload.name} #{target}", "run #{index + 1}/#{config.runs}", summaries[target].last)
          end
        end
        targets.map { |target| aggregate(workload.name, target, summaries[target]) }
      end

      def progress_line(label, position, summary)
        "#{label.ljust(27)} #{position}  #{summary[:throughput_per_s].round.to_s.rjust(8)} cmds/s  " \
          "p50 #{summary[:p50_us].to_s.rjust(9)} us  p99 #{summary[:p99_us].to_s.rjust(9)} us"
      end

      def measure_once(workload, target, config, binaries)
        if target == "rust"
          binary = config.rust_binary || (binaries[workload.name] ||= RustRunner.build(workload.name))
          RustRunner.call(workload, binary: binary, warmup: config.warmup, iterations: config.iterations)
        else
          RubyRunner.call(workload, adapter: target.delete_prefix("ruby:").to_sym,
                                    warmup: config.warmup, iterations: config.iterations)
        end
      end

      def aggregate(domain, target, summaries)
        rates = summaries.map { |summary| summary[:throughput_per_s] }
        median = %i[throughput_per_s p50_us p99_us mean_us max_us drift].to_h do |key|
          [key, Stats.median(summaries.filter_map { |summary| summary[key] })]
        end
        median[:roundtrip_floor_p50_us] = Stats.median(summaries.filter_map { |s| s[:roundtrip_floor_p50_us] })
        median[:by_verb] = median_by_verb(summaries)
        { domain: domain, target: target, runs: summaries, median: median.compact,
          throughput_range: rates.minmax }
      end

      def median_by_verb(summaries)
        summaries.first[:by_verb].keys.to_h do |verb|
          [verb, %i[p50_us p99_us].to_h { |key| [key, Stats.median(summaries.map { |s| s[:by_verb][verb][key] })] }]
        end
      end

      def postgres_version(active)
        PostgresProbe.server_version if active.any? { |target| target.start_with?("ruby:postgres") }
      end
    end
  end
end
