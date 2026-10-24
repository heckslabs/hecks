require_relative "../../refused"

module Hecks
  module Runtime
    # A value object's invariant refused the fields it was built from.
    class InvariantViolation < Hecks::Refused; end
  end
end
