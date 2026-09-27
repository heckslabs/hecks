require_relative "value/invariant_violation"
require_relative "../vocabulary"

module Hecks
  # What runs a booted domain: dispatch, the command/entity/query/policy/saga
  # interpreters, the registry a boot assembles, and the errors below —
  # everything downstream of a `.bluebook`/`.hecksagon`/`.world` declaration.
  # See `lib/hecks/runtime.rb` for the module's own facade and boot entry points.
  module Runtime
    # A dispatched verb names no aggregate, entity or command.
    class UnknownVerb < StandardError; end
    # A settled record failed a command's `ensures`.
    class EnsuresNotMet < StandardError; end

    # A command's `given` refused. `detail` holds the failing comparison's resolved operands
    # ("left: X, right: Y") when the given is a bare comparison, else nil.
    #
    # `detail` rides on `#detailed_message`; `#message` stays byte-for-byte, as specs pin it.
    class GivenNotMet < StandardError
      attr_reader :detail

      # @param message [String, nil] the refusal text
      # @param detail [String, nil] the failing comparison's resolved operands, if any
      def initialize(message = nil, detail: nil)
        super(message)
        @detail = detail
      end

      # Overrides Ruby's own error formatting to append the refusal's detail.
      #
      # @return [String] `message`, with `" (#{detail})"` appended when `detail` is present
      def detailed_message(highlight: false, **opts)
        base = super
        detail ? "#{base} (#{detail})" : base
      end
    end

    # A command addressed a record that does not exist.
    class NotFound < StandardError; end
    # A command is not admissible from the record's current lifecycle state.
    class LifecycleRefused < StandardError; end
    # An argument carries the wrong kind of value for its declared type.
    class TypeMismatch < StandardError; end
    # An argument the command does not declare.
    class UnknownArgument < StandardError; end
    # An argument the command declares but the call omitted.
    class AbsentArgument < StandardError; end
    # A creating command whose derived identity already names a record.
    class AlreadyExists < StandardError; end
    # A required attribute the stored record predates, with no default or translation to fill it.
    # Raised only by `GuardState`; an optional attribute reads nil instead (ADR 0025).
    class AttributeAbsent < StandardError; end
    # A `projects` field the record predates or no rebuild sweep has populated yet.
    # Raised by `GuardState`.
    class ProjectionAbsent < StandardError; end
    # A query or read model declares `authorize policy, tenant: :field` and the caller omitted it.
    class Unauthorized < StandardError; end
    # A `corrects` command whose target event this record never emitted.
    # Raised by `CommandRules::Admissibility#enforce_correction_target`.
    class NothingToCorrect < StandardError; end

    # A CAS write (`expected_version:`) found the stored version moved since the read.
    # A runtime fault, not a domain refusal: the interpreters retry, so it escapes only under
    # sustained contention.
    class StaleWrite < StandardError; end

    # A Lambda-routed domain's refusal (`Runtime::RemoteDispatcher`), with Rust's text verbatim.
    # It is not mapped back to a specific class such as GivenNotMet.
    class RemoteRefusal < StandardError; end

    # The refusals that are the domain saying no, which a reaction records as undelivered.
    # Anything else is a runtime defect and must propagate rather than read as a refusal.
    #
    # UnknownVerb is included on purpose: a cross-domain policy fires where its target domain is
    # not loaded. InvariantViolation is included too, so a value object's refusal is declined.
    # Names come from the language; resolving them here fails at load if one is undefined.
    DOMAIN_REFUSALS = Hecks::Vocabulary.fetch("DomainRefusal").map { |name| const_get(name) }.freeze
  end
end
