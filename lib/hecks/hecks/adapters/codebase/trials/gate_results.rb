# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      class Trials
        # Which checks of a gate run passed, read from what the gate printed: its verdict line and
        # the checks it skipped as unchanged, as `Hecks::Tools::GateReport` spells them. A green
        # verdict names every check that ran; a red one names only the red checks, so the rest of
        # the planned checks that were not skipped passed. A skipped check is not a trial.
        module GateResults
          # `[gate quick] green: rubocop, comment_style; skipped as unchanged: shape_ledger`.
          VERDICT = /^\[gate \S+\] (green|red): ([^;\n]*)/

          # `[gate quick] shape_ledger: unchanged, skipped (green as of ...)`.
          SKIPPED = /^\[gate \S+\] (\S+): unchanged, skipped/

          # What stands between the checks a verdict line names.
          SEPARATOR = /\s*,\s*/

          # What a verdict line says when no check ran.
          NOTHING = "nothing ran"

          module_function

          # @param text [String] what the gate printed
          # @param planned [Array<String>] the ids of the checks the run planned
          # @return [Hash{String => Boolean}] each check that ran, and whether it passed; empty
          #   when the text holds no verdict
          def call(text, planned)
            match = VERDICT.match(text.to_s)
            return {} unless match

            named = names(match[2])
            return named.to_h { |id| [id, true] } if match[1] == "green"

            (planned - text.scan(SKIPPED).flatten).to_h { |id| [id, !named.include?(id)] }
          end

          # @param list [String] what a verdict line says after the verdict
          # @return [Array<String>] the check ids it names
          def names(list)
            list = list.strip
            list == NOTHING ? [] : list.split(SEPARATOR)
          end
        end
      end
    end
  end
end
