
module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end
    class LifecycleRefused < StandardError; end
    class TypeMismatch < StandardError; end
    # An argument the command does not declare. Sibling of TypeMismatch : that one
    # is the right name carrying the wrong thing, this one is a name the command
    # never had. Both are the payload gate refusing before any rule runs.
    class UnknownArgument < StandardError; end

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
    # InvariantViolation belongs here and was missing. A value object refusing
    # its own rule is the domain saying no as plainly as a given is — but the
    # class is declared over in value.rb and never made the list, so the policy
    # and saga interpreters, which rescue exactly these, would let it propagate
    # as though the RUNTIME had broken. A reaction whose target violates an
    # invariant is declined, not crashed. Found by spec/domain_refusal_spec on
    # its first run : every corpus refusal must be a class named here, and 23
    # of banking's were InvariantViolation.
    DOMAIN_REFUSALS = [
      GivenNotMet, InvariantViolation, LifecycleRefused, NotFound, TypeMismatch,
      UnknownArgument, UnknownVerb
    ].freeze
  end
end
