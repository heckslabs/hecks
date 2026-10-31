# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      # Words the reconciliation's dry run and its written report, from the rows it planned.
      module ReconcileReport
        module_function

        # @param row [Reconciliation::Row] one bluebook's row
        # @return [String] the block that reports the row's plan
        def render_row(row)
          return "#{row.name}: its store keeps no eras, so there is nothing to reconcile" unless row.plan

          plan = row.plan
          head = "#{row.name}: current #{plan.current}"
          head += ", latest era #{plan.latest[:ordinal]} (#{plan.latest[:label]})" if plan.latest
          [head, *verdict_lines(plan)].join("\n")
        end

        # @param writes [Array<Reconciliation::Row>] the rows whose plans were carried out
        # @return [String] what was written and deleted, per domain
        def written(writes)
          lines = writes.flat_map { |row| written_lines(row.name, row.plan) }
          ["the audit passed for each composed edge", *lines].join("\n")
        end

        def written_lines(name, plan)
          written = plan.write_path ? ["  wrote #{File.basename(plan.write_path)}"] : []
          ["#{name}: #{plan.labels.join(" -> ")}", *written,
           *plan.removals.map { |path| "  removed #{File.basename(path)}" }]
        end

        def verdict_lines(plan)
          case plan.status
          when :no_era then ["  no era held yet; nothing to reconcile"]
          when :refused then ["  verdict: REFUSED — #{plan.refusal}"]
          when :clean then ["  verdict: clean — nothing to write or delete", "  mints: #{mint_line(plan)}"]
          else write_lines(plan)
          end
        end

        def write_lines(plan)
          lines = ["  chain: #{plan.labels.join(" -> ")}"]
          lines << "  would write: #{File.basename(plan.write_path)}" if plan.write_path
          lines += plan.removals.map { |path| "  would delete: #{File.basename(path)}" }
          lines << "  verdict: write"
          lines << "  mints: #{mint_line(plan)}"
        end

        def mint_line(plan)
          return "no era on the next boot" unless plan.mints

          "era #{plan.latest[:ordinal] + 1} (#{plan.current}) on the next boot of a copy whose world " \
            "declares mint_eras true"
        end
      end
    end
  end
end
