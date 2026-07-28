
module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end
    class LifecycleRefused < StandardError; end
    class TypeMismatch < StandardError; end

    # The domain saying NO — the errors a reaction may legitimately meet and
    # record as an undelivered outcome. A policy whose target refuses is a fact
    # about the domain ; the originating command still stands.
    #
    # Everything ELSE is a defect : a NoMethodError in an interpreter, a
    # NameError from a missing constant, a TypeError from a bad assumption. A
    # blanket `rescue StandardError` used to fold both into one line —
    # `delivered: false, reason: "..."` — so a crash in the runtime was
    # indistinguishable from a rule doing its job, and read as normal operation
    # in the log.
    #
    # UnknownVerb IS one of these, and deliberately : a cross-domain policy
    # (`across "Notifications"`) fires in deployments where that domain is not
    # loaded, and recording the undelivered reaction rather than raising is the
    # design — spec/policy_spec states it in so many words, "records a reaction
    # it cannot deliver rather than swallowing it".
    DOMAIN_REFUSALS = [GivenNotMet, LifecycleRefused, NotFound, TypeMismatch, UnknownVerb].freeze
  end
end
