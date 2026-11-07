module Hecks
  module Bench
    # Renders the gate's reading (`Gate.reading`) as Markdown: each workload's ratio to
    # `ruby:memory` with pass or fail, the workload still blocked, and the kernel's boot cost.
    module GateReport
      module_function

      # @param gate [Hash, nil] `Gate.reading`, or nil when `rust:client` was not measured
      # @return [String, nil] the Markdown block
      def markdown(gate)
        return nil unless gate

        [verdict_table(gate[:verdicts]), overall(gate[:verdicts]), blocked(gate[:blocked]),
         boot_table(gate[:boot_cost])].join("\n\n")
      end

      def verdict_table(verdicts)
        header = ["Gate: `rust:client` against `ruby:memory` (p50 ratio at most 1.0, p99 ratio at most " \
                  "#{Gate::P99_MARGIN}; a core workload reads every step, an extra its named verb)",
                  "", "| workload | p50 ratio | p99 ratio | verdict |", "|---|---:|---:|---|"]
        (header + verdicts.map { |v| verdict_row(v) }).join("\n")
      end

      def verdict_row(verdict)
        "| #{verdict[:domain]} | #{verdict[:p50_ratio]} | #{verdict[:p99_ratio]} | " \
          "#{verdict[:pass] ? "pass" : "fail"} |"
      end

      def overall(verdicts)
        "Gate #{verdicts.any? && verdicts.all? { |v| v[:pass] } ? "PASS" : "FAIL"} " \
          "over #{verdicts.size} measured workload(s)."
      end

      def blocked(blocked)
        blocked.map { |name, reason| "- #{name}: blocked, not measured: #{reason}" }.join("\n")
      end

      def boot_table(costs)
        header = ["Boot cost, spawn + `needs` table + `hello`, against the start-up budget of " \
                  "`docs/cli-measures.md` (room: #{Gate::CEILING_RATIO} - #{Gate::MEASURED_RATIO} floors)",
                  "", "| workload | boot (ms) | floor (s) | added (floors) | room (floors) | fits |",
                  "|---|---:|---:|---:|---:|---|"]
        (header + costs.map { |name, cost| boot_row(name, cost) }).join("\n")
      end

      def boot_row(name, cost)
        "| #{name} | #{(cost[:boot_us] / 1000.0).round(1)} | #{cost[:floor_seconds]} | #{cost[:added_ratio]} | " \
          "#{cost[:room_ratio]} | #{cost[:fits] ? "yes" : "no"} |"
      end
    end
  end
end
