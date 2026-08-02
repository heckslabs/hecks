module Hecksagain
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
        def refuse_unknown_arguments(domain, aggregate, command, args)
          addressing = [:id, *aggregate.identity_heads, reference_key(command)] + correlation_keys(domain)
          known      = (command.attributes.map(&:name) + addressing).compact.map(&:to_sym)
          # SORTED. Payload order is whatever the caller happened to write, and the
          # two runtimes iterate a map differently — an unsorted list makes the same
          # refusal read differently in Ruby and Rust, and parity says so.
          unknown = (args.keys.map(&:to_sym) - known).sort
          return if unknown.empty?

          raise UnknownArgument,
                "#{command.hecks_name} does not declare #{unknown.join(', ')} — " \
                "it takes #{command.attributes.map(&:name).join(', ')}"
        end

        # And it takes ALL of them. The other half of the same sentence, missing
        # until fuzz went looking : a name the command never declared was refused,
        # while a name it DID declare could simply be left out.
        #
        # Ruby happened to refuse `Customer.Register` without its `name` — but by
        # ACCIDENT, and with a lie for a message. `then_set :name, to: :name` found
        # nothing to resolve, passed the literal symbol on, and coercion reported
        # `name is a PersonName — pass its fields as an object`, which describes a
        # mistake the caller did not make. Rust had no such accident and wrote
        # `name: null`. So neither runtime was refusing the real mistake, and the
        # seam between the two accidents is what showed up as a parity SPLIT.
        #
        # No command attribute anywhere in the corpus carries a default — checked,
        # all eight chapters, zero — so there is no optional argument for this to
        # step on. Every declared attribute is a fact the command needs.
        def refuse_absent_arguments(command, args)
          given    = args.keys.map(&:to_sym)
          required = command.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym }
          # SORTED, for the same reason the unknown list is : declaration order is
          # stable but the two runtimes reach it differently, and a refusal has to
          # read identically in both or parity says so.
          absent = (required - given).sort
          return if absent.empty?

          raise AbsentArgument,
                "#{command.hecks_name} was not given #{absent.join(', ')} — " \
                "it takes #{command.attributes.map(&:name).join(', ')}"
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
