module Hecks
  module Bench
    # Runs every requested target against every requested domain and aggregates the runs.
    #
    # Each domain's runs are interleaved across targets (memory, sqlite, ..., memory,
    # sqlite, ...) rather than finished one target at a time, so a burst of unrelated load on
    # the machine lands on every target instead of flattering one of them. Each figure in the
    # result is the median across runs, with the fastest and slowest throughput kept so a noisy
    # measurement shows.
    module Suite
      # Every target `bin/bench` can measure.
      TARGETS = %w[ruby:memory ruby:sqlite ruby:postgres ruby:postgres_era rust].freeze

      # What to measure and how hard.
      #
      # @!attribute domains
      #   @return [Array<String>] workload names, keys of `Workload.all`
      # @!attribute targets
      #   @return [Array<String>] members of `TARGETS`
      # @!attribute warmup
      #   @return [Integer] cycles discarded before each run is timed
      # @!attribute iterations
      #   @return [Integer] cycles timed in each run
      # @!attribute runs
      #   @return [Integer] how many fresh boots of each target to measure per domain
      # @!attribute rust_binary
      #   @return [String, nil] a pre-built binary to use instead of building one; only valid
      #     with a single domain, since a binary embeds exactly one
      Config = Struct.new(:domains, :targets, :warmup, :iterations, :runs, :rust_binary, keyword_init: true)

      module_function

      # Measures everything `config` asks for.
      #
      # @param config [Config] what to measure
      # @param log [#puts] where progress lines go; one line per run
      # @return [Hash{Symbol => Object}] `:environment`, `:config`, `:results` (one entry per
      #   domain and target, see `.aggregate`) and `:skipped` (each skipped target and why)
      # @raise [ArgumentError] if a target or domain is unknown, a count is not positive, or
      #   `rust_binary` is combined with more than one domain
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

      # Checks a configuration before anything is booted.
      #
      # @param config [Config] the configuration to check
      # @return [void]
      # @raise [ArgumentError] on the first problem found
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

      # Finds the targets this machine cannot run.
      #
      # @param config [Config] the configuration whose targets to check
      # @return [Array<Hash{Symbol => String}>] `{target:, reason:}` for each unavailable target
      def unavailable_targets(config)
        postgres = PostgresProbe.unavailable_reason if config.targets.any? { |t| t.start_with?("ruby:postgres") }
        rust = RustRunner.unavailable_reason(binary: config.rust_binary) if config.targets.include?("rust")
        config.targets.filter_map do |target|
          reason = target == "rust" ? rust : (postgres if target.start_with?("ruby:postgres"))
          { target: target, reason: reason } if reason
        end
      end

      # Measures one domain across every active target, `config.runs` times each.
      #
      # @param workload [Workload] the domain's commands
      # @param targets [Array<String>] the targets that can run here
      # @param config [Config] warmup, iterations, runs and any binary override
      # @param log [#puts] where progress lines go
      # @return [Array<Hash>] one aggregated entry per target
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

      # Formats the one line printed as each run finishes.
      #
      # @param label [String] the domain and target
      # @param position [String] which run of how many, e.g. `"2/3"`
      # @param summary [Hash] the run's `Run#summary`
      # @return [String] the progress line
      def progress_line(label, position, summary)
        "#{label.ljust(27)} #{position}  #{summary[:throughput_per_s].round.to_s.rjust(8)} cmds/s  " \
          "p50 #{summary[:p50_us].to_s.rjust(9)} us  p99 #{summary[:p99_us].to_s.rjust(9)} us"
      end

      # Runs one target once.
      #
      # @param workload [Workload] the domain's commands
      # @param target [String] a member of `TARGETS`
      # @param config [Config] warmup, iterations and any binary override
      # @param binaries [Hash{String => String}] Rust binaries already built, by domain name;
      #   filled in as they are built
      # @return [Run] the run's timings
      def measure_once(workload, target, config, binaries)
        if target == "rust"
          binary = config.rust_binary || (binaries[workload.name] ||= RustRunner.build(workload.name))
          RustRunner.call(workload, binary: binary, warmup: config.warmup, iterations: config.iterations)
        else
          RubyRunner.call(workload, adapter: target.delete_prefix("ruby:").to_sym,
                                    warmup: config.warmup, iterations: config.iterations)
        end
      end

      # Reduces one target's runs to a single entry.
      #
      # @param domain [String] the workload name
      # @param target [String] the target name
      # @param summaries [Array<Hash>] each run's `Run#summary`
      # @return [Hash{Symbol => Object}] `:domain`, `:target`, `:runs` (the raw summaries),
      #   `:median` (the median of each run's throughput, p50, p99 and drift, plus
      #   `:by_verb`), and `:throughput_range` (`[slowest, fastest]` across runs)
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

      # Takes each verb's median p50 and p99 across runs.
      #
      # @param summaries [Array<Hash>] each run's `Run#summary`
      # @return [Hash{String => Hash{Symbol => Float}}] `:p50_us` and `:p99_us` per verb
      def median_by_verb(summaries)
        summaries.first[:by_verb].keys.to_h do |verb|
          [verb, %i[p50_us p99_us].to_h { |key| [key, Stats.median(summaries.map { |s| s[:by_verb][verb][key] })] }]
        end
      end

      # Reads the Postgres server version if a Postgres target ran.
      #
      # @param active [Array<String>] the targets that ran
      # @return [String, nil] the server version, or nil when no Postgres target ran
      def postgres_version(active)
        PostgresProbe.server_version if active.any? { |target| target.start_with?("ruby:postgres") }
      end
    end
  end
end
