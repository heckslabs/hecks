module Hecks
  module Adapters
    # A `clock` port fulfillment that satisfies every gate `verify!` had
    # BEFORE `Port#answers` (port name, verb, `.world` settings) but is
    # missing the one method a live dispatch would actually call —
    # exactly the shape `spec/runtime/registry/verification_answers_spec
    # .rb` exists to prove now fails at BOOT instead of at first dispatch.
    module BrokenClock
      module_function

      def not_now = "wrong method name entirely"
    end
  end
end
