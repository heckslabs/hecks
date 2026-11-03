require_relative "../refused"
require_relative "value/invariant_violation"
require_relative "../vocabulary"

module Hecks
  # What runs a booted domain: dispatch, the command/entity/query/policy/saga
  # interpreters, the registry a boot assembles, and the errors below —
  # everything downstream of a `.bluebook`/`.hecksagon`/`.world` declaration.
  # See `lib/hecks/runtime.rb` for the module's own facade and boot entry points.
  module Runtime
    # A dispatched verb names no aggregate, entity or command.
    class UnknownVerb < Hecks::Refused; end
    # A settled record failed a command's `ensures`.
    class EnsuresNotMet < Hecks::Refused; end

    # A command's `given` refused. `detail` holds the failing comparison's resolved operands
    # ("left: X, right: Y") when the given is a bare comparison, else nil.
    #
    # `detail` rides on `#detailed_message`; `#message` stays byte-for-byte, as specs pin it.
    class GivenNotMet < Hecks::Refused
      attr_reader :detail

      # @param message [String, nil] the refusal text
      # @param detail [String, nil] the failing comparison's resolved operands, if any
      # @param options [Hash] `attribute:`, `rule:`, `stage:` and `path:`, as `Hecks::Refused` takes
      def initialize(message = nil, detail: nil, **)
        super(message, **)
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
    class NotFound < Hecks::Refused; end

    # A command is not admissible from the record's current lifecycle state.
    class LifecycleRefused < Hecks::Refused; end
    # An argument carries the wrong kind of value for its declared type.
    class TypeMismatch < Hecks::Refused; end
    # An argument the command does not declare.
    class UnknownArgument < Hecks::Refused; end

    # An argument the command declares but the call omitted.
    class AbsentArgument < Hecks::Refused; end

    # A creating command whose derived identity already names a record.
    class AlreadyExists < Hecks::Refused; end
    # A required attribute the stored record predates, with no default or translation to fill it.
    # Raised only by `GuardState`; an optional attribute reads nil instead (ADR 0025).
    class AttributeAbsent < Hecks::Refused; end
    # A `projects` field the record predates or no rebuild sweep has populated yet.
    # Raised by `GuardState`.
    class ProjectionAbsent < Hecks::Refused; end

    # A query or read model declares `authorize policy, tenant: :field` and the caller omitted it.
    class Unauthorized < Hecks::Refused; end

    # A `corrects` command whose target event this record never emitted.
    # Raised by `CommandRules::Admissibility#enforce_correction_target`.
    class NothingToCorrect < Hecks::Refused; end

    # A CAS write (`expected_version:`) found the stored version moved since the read.
    # A runtime fault, not a domain refusal: the interpreters retry, so it escapes only under
    # sustained contention.
    class StaleWrite < StandardError; end

    # A Lambda-routed domain's refusal (`Adapters::Lambda::RemoteDispatcher`), with Rust's text
    # verbatim.
    # It is not mapped back to a specific class such as GivenNotMet.
    class RemoteRefusal < Hecks::Refused; end

    # A wasm plugin's refusal of a question it was asked (`Runtime::WasmPlugin`), with its own
    # words: a time zone it does not know, a window it will not expand.
    class PluginRefusal < StandardError; end

    # The refusals that are the domain saying no, which a reaction records as undelivered.
    # Anything else is a runtime defect and must propagate rather than read as a refusal.
    #
    # UnknownVerb is included on purpose: a cross-domain policy fires where its target domain is
    # not loaded. InvariantViolation is included too, so a value object's refusal is declined.
    # Names come from the language; resolving them here fails at load if one is undefined.
    # Each is a `Hecks::Refused`, and nothing else is, so rescuing either catches the same set.
    DOMAIN_REFUSALS = Hecks::Vocabulary.fetch("DomainRefusal").map { |name| const_get(name) }.freeze

    # The errors that mean the code is wrong, not that the outside world said no: a name that
    # does not resolve (`NameError`, and `NoMethodError` under it), a value of the wrong class
    # (`TypeError`), a write to a frozen value (`FrozenError`), and code that would not load
    # (`ScriptError`: `LoadError`, `NotImplementedError`, `SyntaxError`). An ask that meets one
    # raises it instead of announcing its `refuses` event, so the defect is seen where it happens.
    #
    # `ArgumentError` is left out on purpose: adapters raise its subclasses to refuse input they
    # were handed (`TenantProvisioner::Refused`, `Composer::Workspace::OutsideWorkspace`), and
    # parsing outside data raises it (`Integer("x")`, `Date::Error`), so it is the world saying no
    # as often as it is a wrong call.
    PROGRAMMING_ERRORS = [NameError, TypeError, FrozenError, ScriptError].freeze

    # @param error [Exception] the error an adapter raised
    # @return [Boolean] whether `error` is a defect in the code rather than a refusal
    def self.programming_error?(error) = PROGRAMMING_ERRORS.any? { |kind| error.is_a?(kind) }

    # The refusal text of a failure an ask records: its class and message. An error raised with no
    # message still names its class, so a refusal never arrives empty.
    #
    # @param error [Exception] the error an adapter raised
    # @return [String] `"Class: message"`, never blank
    def self.failure_reason(error)
      message = error.message.to_s.strip
      "#{error.class}: #{message.empty? ? "raised with no message" : message}"
    end
  end
end
