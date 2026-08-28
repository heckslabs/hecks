require_relative "../../naming"
require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class CommandInterpreter
      # The payload gate: a command takes the arguments it declares — all of
      # them, and no others.
      module ArgumentGate
        private

        # Anything else used to ride along in the payload untouched —
        # normalize_args walks the DECLARED attributes, so a name the command
        # never had was simply never looked at. A misspelled argument did
        # nothing, in silence.
        #
        # The keys that are legitimately not attributes are the ones that ADDRESS
        # the aggregate rather than describe it : `id`, whatever the aggregate is
        # identified by, and the reference key of the root a command reaches
        # through. Refusing those would refuse every dispatch there is.
        #
        # `extra_identity_heads:` — EntityInterpreter's own callers only. An
        # entity dispatch addresses not just the root aggregate but every
        # entity ALONG THE CHAIN it walks to reach the piece the command
        # actually belongs to (`Handler.Dispatch.Bind` is two hops), and each
        # hop's own `identity_heads` is addressing the same way the root's
        # are — `element_of` (entity_element.rb) reads them straight out of
        # `args` to find the element, never as a fact the command itself
        # declares. `[]` for a plain aggregate/port-operation dispatch, which
        # has no chain to add.
        def refuse_unknown_arguments(domain, aggregate, command, args, extra_identity_heads: [])
          addressing = [:id, *aggregate.identity_heads, *extra_identity_heads, reference_key(command)] +
                       correlation_keys(domain)
          known      = (command.attributes.map(&:name) + addressing).compact.map(&:to_sym)
          # SORTED. Payload order is whatever the caller happened to write, and
          # refusal wording is contract — pinned byte-for-byte by the corpus, so
          # it cannot depend on hash iteration order.
          unknown = (args.keys.map(&:to_sym) - known).sort
          return if unknown.empty?

          raise UnknownArgument,
                RefusalWording.render("UnknownArgument", "unknown_args",
                                      command: command.hecks_name, unknown: unknown.join(", "),
                                      declared: declared_reading(command))
        end

        # And it takes ALL of them. The other half of the same sentence, missing
        # until fuzz went looking : a name the command never declared was refused,
        # while a name it DID declare could simply be left out.
        #
        # `Customer.Register` without its `name` used to be refused — but by
        # ACCIDENT, and with a lie for a message. `then_set :name, to: :name` found
        # nothing to resolve, passed the literal symbol on, and coercion reported
        # `name is a PersonName — pass its fields as an object`, which describes a
        # mistake the caller did not make. The real mistake — an argument simply
        # missing — was never the one named, and nothing refused it on purpose.
        #
        # No command attribute anywhere in the corpus carries a default — checked,
        # all eight chapters, zero — so there is no optional argument for this to
        # step on. Every declared attribute is a fact the command needs.
        #
        # `aggregate:` — PRESENT ONLY FOR A PORT OPERATION. An aggregate
        # command's own self-address never reaches this list at all
        # (`CommandBuilder#reference_to`'s bare self-reference mints no
        # attribute to be absent) — but `PortOperationBuilder#reference_to`
        # ALWAYS mints one (this file's own header on `PortOperation`: "no
        # creates?/acts_on distinction to protect"), because an operation
        # historically had no OTHER way to say which record it addressed.
        # `to:` is that other way now (`Dispatcher#port_invocation`
        # promotes the identity attribute's own value out of the payload
        # and into routing) — which left the attribute still DECLARED,
        # still non-optional, and now never present in `args` at all: every
        # operation with an identity attribute refused its own well-formed
        # calls, dispatched exactly the way `to:` intends. Exempted here on
        # the same terms an aggregate command's self-address always was —
        # an address, not a fact the operation still needs handed back.
        def refuse_absent_arguments(command, args, aggregate: nil)
          given    = args.keys.map(&:to_sym)
          exempt   = aggregate && command.respond_to?(:identity_attribute) &&
                     command.identity_attribute(aggregate.hecks_name)&.name
          required = command.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym } - [exempt]
          # SORTED, for the same reason the unknown list is : refusal wording is
          # contract, and a pinned wording cannot depend on the order a set
          # difference happens to be computed in.
          absent = (required - given).sort
          return if absent.empty?

          raise AbsentArgument,
                RefusalWording.render("AbsentArgument", "absent_args",
                                      command: command.hecks_name, absent: absent.join(", "),
                                      declared: declared_reading(command))
        end

        # A COMMAND THAT DECLARES NOTHING STILL HAS TO SAY SO. `Account
        # .Freeze` is `reference_to Account` and no attributes at all, so
        # `{declared}` rendered empty and the sentence trailed off mid-
        # clause : "Freeze does not declare standing — it takes ". Read
        # against a real refusal that shape is worse than unhelpful — it
        # looks like the message itself is broken, right where a caller
        # is already trying to work out what went wrong.
        #
        # Only the empty case changes. Every command that declares even
        # one attribute renders exactly as it did before, because refusal
        # wording is contract and pinned byte-for-byte by the corpus (see
        # `refuse_unknown_arguments`' own note on sorting for why).
        def declared_reading(command)
          declared = command.attributes.map(&:name)
          declared.empty? ? "none" : declared.join(", ")
        end

        # What a process manager correlates by is ROUTING, not description. A saga
        # threads its correlation key through every leg it dispatches so the event
        # each leg emits carries it and the next step can be correlated — so the key
        # arrives on commands that never declare it, and legitimately.
        #
        # This is the weakest part of the gate. Correlation is the SAGA's business,
        # and the better shape is for the saga to stamp its own key onto the event
        # it caused rather than smuggle it through the command's payload. Until it
        # does, refusing the key here would break every saga in the corpus.
        def correlation_keys(domain)
          Array(@registry.bluebook(domain)&.process_managers)
            .filter_map { |saga| saga.correlates_by && saga.correlation_head }
        end

        def reference_key(command)
          target = command.references.to_s
          return nil if target.empty?

          Naming.reference_key(target)
        end
      end
    end
  end
end
