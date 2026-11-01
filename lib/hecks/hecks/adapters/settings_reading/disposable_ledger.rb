# frozen_string_literal: true

module Hecks
  module Adapters
    class SettingsReading
      # The `disposable ledger` row of `hecks config`: whether the copy's world declares its
      # PostgresEra store a disposable tooling ledger, which needs no era for a shape change, and
      # whether the world or the default says so.
      module DisposableLedger
        # @param directory [String] the domain directory
        # @return [Array(String, String, String)] the row's name, value and source
        def disposable_ledger(directory)
          registry = Hecks.describe(directory).registry
          declared = registry.binding_settings(registry.first_domain_name, Ports::Persistence::VERB, "PostgresEra")
          ["disposable ledger", disposable_wording(declared), declared.key?(:disposable_ledger) ? "world" : "default"]
        rescue StandardError => e
          ["disposable ledger", "could not be read", first_line(e.message)]
        end

        private

        def disposable_wording(declared)
          if [true, "true"].include?(declared[:disposable_ledger])
            "yes: a shape change needs no era, and a breaking one archives its rows"
          else
            "no: a shape change needs an era"
          end
        end
      end
    end
  end
end
