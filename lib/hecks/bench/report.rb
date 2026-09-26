require "json"

module Hecks
  module Bench
    # Renders a `Suite.call` result as Markdown or JSON.
    #
    # The Markdown is what `docs/benchmarks.md` pastes in. It states the machine, the
    # counts and the skipped targets next to the table, so a copied table is never a
    # bare number.
    module Report
      module_function

      # Renders the whole report as Markdown.
      #
      # @param result [Hash] the value `Suite.call` returned
      # @return [String] the environment, the configuration, the table and any skipped targets
      def markdown(result)
        [environment_block(result[:environment]), configuration_block(result[:config]),
         table(result[:results]), floor_block(result[:results]), skipped_block(result[:skipped])]
          .compact.join("\n\n") << "\n"
      end

      # Renders the whole report as JSON.
      #
      # @param result [Hash] the value `Suite.call` returned
      # @return [String] pretty-printed JSON of `result`
      def json(result)
        JSON.pretty_generate(result)
      end

      # Renders the results table.
      #
      # @param results [Array<Hash>] the `:results` of `Suite.call`
      # @return [String] a Markdown table with one row per domain and target
      def table(results)
        header = ["| domain | target | commands/s | range across runs | p50 (us) | p99 (us) | drift |",
                  "|---|---|---:|---:|---:|---:|---:|"]
        (header + results.map { |entry| row(entry) }).join("\n")
      end

      # Renders one table row.
      #
      # @param entry [Hash] one aggregated result
      # @return [String] the row as Markdown
      def row(entry)
        median = entry[:median]
        low, high = entry[:throughput_range]
        cells = [entry[:domain], entry[:target], number(median[:throughput_per_s], 0),
                 "#{number(low, 0)} to #{number(high, 0)}", number(median[:p50_us], 1),
                 number(median[:p99_us], 1), number(median[:drift], 2)]
        "| #{cells.join(' | ')} |"
      end

      # Formats a number with thousands separators.
      #
      # @param value [Numeric, nil] the number
      # @param places [Integer] digits after the decimal point
      # @return [String] the formatted number, or `"n/a"` for nil
      def number(value, places)
        return "n/a" if value.nil?

        whole, fraction = format("%.#{places}f", value).split(".")
        [whole.gsub(/(\d)(?=(\d{3})+\z)/, '\1,'), fraction].compact.join(".")
      end

      # Renders the machine and toolchain.
      #
      # @param environment [Hash] the `:environment` of `Suite.call`
      # @return [String] a Markdown bullet list
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

      # Renders how hard the run pushed.
      #
      # @param config [Hash] the `:config` of `Suite.call`
      # @return [String] one sentence with the warmup, iteration and run counts
      def configuration_block(config)
        "Warmup #{config[:warmup]} cycles, then #{config[:iterations]} timed cycles per run, " \
          "median of #{config[:runs]} run(s), domains: #{config[:domains].join(', ')}."
      end

      # Renders the Rust round-trip floor, if a Rust target ran.
      #
      # @param results [Array<Hash>] the `:results` of `Suite.call`
      # @return [String, nil] a sentence naming each domain's floor, or nil without a Rust result
      def floor_block(results)
        floors = results.select { |entry| entry[:target] == "rust" }
                        .map { |entry| "#{entry[:domain]} #{number(entry[:median][:roundtrip_floor_p50_us], 1)} us" }
        return nil if floors.empty?

        "Rust pipe round-trip floor (p50, a step refused at once): #{floors.join(', ')}."
      end

      # Renders the targets that did not run.
      #
      # @param skipped [Array<Hash>] the `:skipped` of `Suite.call`
      # @return [String, nil] one line per skipped target, or nil when none were skipped
      def skipped_block(skipped)
        return nil if skipped.empty?

        (["Skipped:"] + skipped.map { |entry| "- #{entry[:target]}: #{entry[:reason]}" }).join("\n")
      end
    end
  end
end
