require "hecks"

module Hecks
  module Composer
    # The closed lists the Composer's code is held to, read from `composer.bluebook` on first use so
    # no copy lives in Ruby: what a prompt can ask for (`Request.Intent`) and which commands the
    # palette runs without a confirmation phrase (`Palette.SafeCommand`).
    module Declared
      FILE = File.expand_path("bluebook/composer.bluebook", __dir__).freeze

      module_function

      # @param aggregate [String] an aggregate of the Composer bluebook
      # @param value_object [String] a closed-set value object of that aggregate
      # @return [Array<String>] its members, frozen
      def closed_set(aggregate, value_object)
        Framework.closed_values(declaration, aggregate, value_object)
      end

      # @return [Bluebook::Declaration] the Composer bluebook, loaded once in a scratch registry
      def declaration
        @declaration ||= Framework.declaration_at(FILE, "Composer")
      end
    end
  end
end
