module Hecks
  module Adapters
    # A `clock` port fulfillment that satisfies every gate `verify!` had
    # before `Port#answers` (port name, verb, `.world` settings) but is
    # missing the one method a live dispatch would actually call —
    # exactly the shape `spec/runtime/registry/verification_answers_spec
    # .rb` exists to prove now fails at boot instead of at first dispatch.
    module BrokenClock
      module_function

      # Stands in for the clock port's real method under a wrong name, so a boot-time
      # check can prove it catches a missing method instead of waiting for first dispatch.
      #
      # @return [String] a fixed placeholder string, never a time
      def not_now = "wrong method name entirely"
    end
  end
end
