
module Hecksagain
  module Runtime
    class CommandRules
      attr_reader :registry

      # The ops Runtime::CommandInterpreter applies. Declared the same way in
      # Vocabulary::MutationOp (language/bluebook/vocabulary.bluebook) —
      # spec/vocabulary_conformance_spec holds the two tables equal, so
      # increment/decrement's sign cannot drift from what the language says
      # each op means. set/append carry no sign — they do no arithmetic.
      MutationOp = Struct.new(:name, :sign, keyword_init: true)

      MUTATION_OPS = [
        MutationOp.new(name: "set",       sign: nil),
        MutationOp.new(name: "append",    sign: nil),
        MutationOp.new(name: "increment", sign: 1),
        MutationOp.new(name: "decrement", sign: -1)
      ].freeze

      def initialize(registry)
        @registry = registry
      end

      def enforce_givens(subject, command, args)
        command.givens.each do |given|
          next if Bluebook::Expression::Evaluator.call(given.canonical, subject, args)

          raise GivenNotMet, "#{command.hecks_name} refused — #{given.description}"
        end
      end

      def admissible_transition(declaring, command, subject)
        lifecycle = declaring.lifecycle
        return nil unless lifecycle

        candidates = lifecycle.transitions_for(command.hecks_name)
        return nil if candidates.empty?

        current  = subject[lifecycle.field].to_s
        admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
        return admitted if admitted

        allowed = candidates.flat_map { |t| Array(t.from) }.uniq
        raise LifecycleRefused,
              "#{command.hecks_name} refused — #{lifecycle.field} is #{Rendering.describe(current)}, and " \
              "#{command.hecks_name} moves it only from #{allowed.map(&:inspect).join(' or ')}"
      end

      # A mutation's source is either the NAME OF AN ARGUMENT or a LITERAL, and
      # the two are told apart by type : a Symbol is always a name, a String or a
      # number is always a value. Checked across all eight chapters — `to: :name`
      # and `to: "sold"`, never a Symbol meant as a value.
      #
      # `&& args.key?(source)` used to guard the lookup, and that guard is what
      # made an ABSENT argument fall through to `source` and return THE SYMBOL
      # ITSELF as the value. `Customer.Register` without its `name` set name to
      # the literal `:name`, coercion met a Symbol where a PersonName belonged,
      # and Ruby refused with "name is a PersonName — pass its fields as an
      # object, not :name" — a message describing a mistake the caller had not
      # made. Rust reads the same IR structurally (`kind: "argument"` vs a literal
      # `value`) and returned Null, so it accepted and wrote `name: null`. Neither
      # runtime was refusing the real mistake and they disagreed about what to do
      # instead, which is how it surfaced : as a parity SPLIT, from fuzz.
      #
      # Absent now resolves to nil in both. Whether it should be REFUSED instead
      # is a separate question — the language cannot yet say which arguments are
      # optional, and the meta-domain has plenty that are.
      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol)

        source
      end

      # A reference must point at something that EXISTS.
      #
      # `reference_to Customer` is the one guarantee an aggregate reference is
      # for, and it was declared 14 times across banking and enforced nowhere :
      # an Account could belong to a customer who was never registered, in both
      # runtimes, and parity stayed green because both were equally permissive
      # and no corpus step ever passed a dangling reference.
      #
      # Resolved here rather than in coercion because coercion is pure — it
      # holds no repository. A reference INTO ANOTHER DOMAIN is left alone : a
      # cross-domain target may legitimately not be loaded, which is the same
      # reading `across` policies already get.
      #
      # Shared by CommandInterpreter and EntityInterpreter — an entity command
      # can declare a reference-typed attribute the same way an aggregate
      # command can, even though nothing in the real corpus does yet.
      def resolve_references(domain, command, args)
        command.attributes.each do |attribute|
          next unless attribute.reference?
          next unless args.key?(attribute.name)

          held = args[attribute.name]
          next if held.nil?

          target = referenced_aggregate(attribute)
          next unless target

          # The id itself — a reference that arrived as anything else was
          # already refused at the payload gate.
          key = held.to_s
          next if key.to_s.empty?
          next if @registry.repository(domain, target).find(key)

          raise NotFound,
                "no #{target.name} with #{target.identified_by || :id} #{key.inspect}"
        end
      end

      # The reference RESOLVES itself — through the chapter's own IR, so the
      # bluebook's declared heads are the index. This used to regex the target's
      # name out of "Reference<Customer>" and then search
      # `registry.bluebook(domain).aggregates` for it — and later reached the
      # target through Ruby's constant tree, a class thrown away for its `.ir`
      # the moment it was found.
      def referenced_aggregate(attribute)
        attribute.type.resolve
      end


      def arithmetic(current, amount, target, sign)
        op      = sign.positive? ? "increment" : "decrement"
        current ||= 0

        if current.is_a?(Value) && amount.is_a?(Value)
          return arithmetic_value_object(current, amount, target, sign, op)
        end

        unless amount.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{target} needs an Integer, got #{Rendering.describe(amount)}"
        end
        unless current.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{target} needs an Integer #{target}, got #{Rendering.describe(current)}"
        end

        current + (sign * amount)
      end

      def arithmetic_value_object(current, amount, target, sign, op)
        current_fields = current.to_h
        amount_fields  = amount.to_h
        shared_numeric = current_fields.keys.select do |field|
          current_fields[field].is_a?(Integer) && amount_fields[field].is_a?(Integer)
        end
        unless shared_numeric.size == 1
          raise TypeMismatch,
                "#{op} of #{target} needs a value object with one shared Integer field"
        end

        field = shared_numeric.first
        current.with(field, current[field] + (sign * amount[field]))
      end

      def sign_of(op) = MUTATION_OPS.find { |candidate| candidate.name == op.to_s }&.sign || -1

      def emit(command, domain, aggregate, instance, args, repository)
        command.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{domain}::#{aggregate.hecks_name}",
            id:          instance.id,
            payload:     args,
            occurred_at: Time.now.utc.iso8601
          )
          @registry.event_log << event
          repository.record_event(event) if repository.respond_to?(:record_event)
          event
        end
      end
    end
  end
end
