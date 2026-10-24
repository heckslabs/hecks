module Hecks
  # The domain saying no: the parent of every class `Runtime::DOMAIN_REFUSALS` names, so a
  # driving adapter can `rescue Hecks::Refused` instead of splatting the list. A runtime fault
  # (`Runtime::StaleWrite`, `Runtime::WiringError`) is not one.
  class Refused < StandardError
    # @return [Symbol, nil] the attribute the refusal is about, when it is about one; the
    #   first in sorted order when it names several
    attr_reader :attribute

    # @param message [String, nil] the refusal text
    # @param attribute [Symbol, String, nil] the attribute the refusal is about, if any
    def initialize(message = nil, attribute: nil)
      super(message)
      @attribute = attribute&.to_sym
    end
  end
end
