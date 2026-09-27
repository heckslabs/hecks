require "json"

module Hecks
  module Bench
    # Renders a `Suite.call` result as Markdown or JSON.
    # The Markdown carries machine, counts and skips so a pasted table is never a bare number.
    module Report
      module_function

      def markdown(result)
        [environment_block(result[:environment]), configuration_block(result[:config]),
         table(result[:results]), floor_block(result[:results]), skipped_block(result[:skipped])]
          .compact.join("\n\n") << "\n"
      end

      def json(result)
        JSON.pretty_generate(result)
      end

      def table(results)
        header = ["| domain | target | commands/s | range across runs | p50 (us) | p99 (us) | drift |",
                  "|---|---|---:|---:|---:|---:|---:|"]
        (header + results.map { |entry| row(entry) }).join("\n")
      end

      def row(entry)
        median = entry[:median]
        low, high = entry[:throughput_range]
        cells = [entry[:domain], entry[:target], number(median[:throughput_per_s], 0),
                 "#{number(low, 0)} to #{number(high, 0)}", number(median[:p50_us], 1),
                 number(median[:p99_us], 1), number(median[:drift], 2)]
        "| #{cells.join(' | ')} |"
      end

      def number(value, places)
        return "n/a" if value.nil?

        whole, fraction = format("%.#{places}f", value).split(".")
        [whole.gsub(/(\d)(?=(\d{3})+\z)/, '\1,'), fraction].compact.join(".")
      end

      def environment_block(environment)
        load = environment[:load_average]
        lines = [
          "- CPU: #{environment[:cpu]} (#{environment[:cores]} cores), #{environment[:memory_gib]} GiB",
          "- OS: #{environment[:os]}",
          "- Ruby: #{environment[:ruby]} (YJIT #{environment[:yjit] ? 'on' : 'off'})",
          "- Rust: #{environment[:rustc]}; #{environment[:cargo]}",
          "- Hecks: #{environment[:hecks]} at #{environment[:commit]}",
          "- Load average (1 min) before and after: #{load[:before]} and #{load[:after]}"
        ]
        lines << "- Postgres: #{environment[:postgres]}" if environment[:postgres]
        lines.join("\n")
      end

      def configuration_block(config)
        "Warmup #{config[:warmup]} cycles, then #{config[:iterations]} timed cycles per run, " \
          "median of #{config[:runs]} run(s), domains: #{config[:domains].join(', ')}."
      end

      def floor_block(results)
        floors = results.select { |entry| entry[:target] == "rust" }
                        .map { |entry| "#{entry[:domain]} #{number(entry[:median][:roundtrip_floor_p50_us], 1)} us" }
        return nil if floors.empty?

        "Rust pipe round-trip floor (p50, a step refused at once): #{floors.join(', ')}."
      end

      def skipped_block(skipped)
        return nil if skipped.empty?

        (["Skipped:"] + skipped.map { |entry| "- #{entry[:target]}: #{entry[:reason]}" }).join("\n")
      end
    end
  end
end
