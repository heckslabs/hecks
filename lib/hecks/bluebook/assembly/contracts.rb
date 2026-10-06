require_relative "contracts/structure"
require_relative "contracts/rules"
require_relative "contracts/sagas"
require_relative "contracts/read_models"

module Hecks
  module Bluebook
    # Reopened for `CONTRACTS`, the table of each category's own `Contract`;
    # see contract.rb for the struct format each entry below fills in.
    class Assembly
      # One table of what each category needs beyond what the language states:
      # holder, make (:declare vs :new), and fields. spec/assembly_spec checks
      # it against the language, so an unconsumed declared field fails loudly.
      def self.contract(category) = CONTRACTS.fetch(category.to_s)

      CONTRACTS = {
        **STRUCTURE,
        **RULES,
        **SAGAS,
        **READ_MODELS
      }.freeze
    end
  end
end
