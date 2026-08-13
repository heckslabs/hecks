require_relative "value/invariant_violation"
require_relative "../vocabulary"


module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class EnsuresNotMet < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end
    class LifecycleRefused < StandardError; end
    class TypeMismatch < StandardError; end
    # An argument the command does not declare. Sibling of TypeMismatch : that one
    # is the right name carrying the wrong thing, this one is a name the command
    # never had. Both are the payload gate refusing before any rule runs.
    class UnknownArgument < StandardError; end
    # The third of the trio, and the one that was missing : a name the command DOES
    # declare, absent. TypeMismatch is the right name carrying the wrong thing,
    # UnknownArgument a name that was never declared, AbsentArgument a declared name
    # that never arrived. Between them they say a command takes exactly the
    # arguments it declares — no others, and all of them.
    class AbsentArgument < StandardError; end
    # A creating command whose derived identity already names a record. The
    # record it would have overwritten stands ; the dispatch that tried to
    # mint a second one over it is what refuses.
    class AlreadyExists < StandardError; end
    # A query or read model declares `authorize policy, tenant: :field` and
    # the caller did not pass that field — the one half of `authorize` this
    # runtime can enforce without a caller-identity system: the boundary
    # itself, not whether the caller actually holds `policy`. See
    # Runtime::TenantScope.
    class Unauthorized < StandardError; end

    # A Lambda-routed domain's own refusal (rust/host, `Runtime::
    # RemoteDispatcher`), carrying Rust's own refusal text verbatim —
    # NOT yet mapped back to the specific matching class above
    # (GivenNotMet vs. EnsuresNotMet vs. ...), a real, known,
    # documented gap: the WASM projector's own event/refusal-wording
    # parity work (ADR 0021) makes the TEXT match Ruby's, but nothing
    # yet parses that text back into a typed Ruby exception the way a
    # local dispatch already raises one directly. Callers that only
    # need "the domain said no" (not which specific rule) are
    # unaffected; callers pattern-matching a SPECIFIC refusal class
    # against a Lambda-routed domain are the ones this gap would bite.
    class RemoteRefusal < StandardError; end

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
    # THE NAMES COME FROM THE LANGUAGE, the classes from this module.
    # `DomainRefusal` declares WHICH refusals are the domain's own —
    # a rule the caller broke — as against a runtime fault. Resolving
    # each name here means a refusal declared but never defined fails
    # at load with a NameError, rather than being quietly absent from
    # a list nothing re-checks.
    DOMAIN_REFUSALS = Hecksagain::Vocabulary.fetch("DomainRefusal").map { |name| const_get(name) }.freeze
  end
end
