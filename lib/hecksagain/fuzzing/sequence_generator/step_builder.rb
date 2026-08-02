module Hecksagain
  module Fuzzing
    class SequenceGenerator
      # Turn a picked entry into a corpus step: generate its arguments,
      # occasionally malform exactly one of them, shape its identity, and
      # dispatch it for real.
      module StepBuilder
        private

        def build_query_step(runtime, entry)
          args = args_for(entry[:query].attributes, entry[:aggregate])
          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        def build_command_step(runtime, catalog, entry)
          args = args_for(entry[:command].attributes, entry[:aggregate])
          add_identity!(args, entry)

          outcome = safe_call { runtime.dispatch(entry[:verb], **symbolize(args)) }
          record_outcome(catalog, entry, args) if outcome
          { "verb" => entry[:verb], "args" => args }
        end

        def args_for(attributes, aggregate)
          args = attributes.each_with_object({}) do |attribute, built|
            # List-typed direct command arguments have no example in this repo's
            # domains today — every list is populated via a per-element append
            # command instead (docs/porting/behavior-notes.md). Skipped rather
            # than guessed at.
            next if attribute.list?

            built[attribute.name.to_s] = ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids)
          end

          malform(args, attributes, aggregate)
        end

        # ONE MALFORMATION AT A TIME, and usually none. A step whose payload is
        # wrong in three ways only ever proves which check runs first ; wrong in
        # exactly one way names the check that fired. And the rate stays low on
        # purpose — a corrupted step is almost always refused, a sequence of
        # refusals reaches no state at all, and bin/fuzz already counts those as
        # SILENT rather than scoring them.
        def malform(args, attributes, aggregate)
          return args if args.empty? || @random.rand >= MALFORMED_ARGUMENT_PROBABILITY

          case @random.rand(3)
          when 0 then corrupt_one(args, attributes, aggregate)
          when 1 then drop_one(args, aggregate)
          else        args.merge([InvalidValueGenerator.undeclared_argument(random: @random)].to_h)
          end
        end

        # NEVER THE IDENTITY. A creating command with no id auto-mints one, and the
        # two runtimes mint differently by design — Ruby a random hex, Rust a
        # counter — so dropping it manufactures a disagreement that says nothing
        # about either runtime's behaviour. Every step in the hand-written corpus
        # supplies an id for the same reason. Whether an auto-minted id OUGHT to
        # agree is a real question, but it is not one a payload fuzzer can ask.
        def drop_one(args, aggregate)
          identity  = (aggregate.identified_by || :id).to_s
          droppable = args.keys - [identity, "id"]
          return args if droppable.empty?

          args.reject { |name, _| name == droppable.sample(random: @random) }
        end

        def corrupt_one(args, attributes, aggregate)
          named = attributes.reject(&:list?).select { |attribute| args.key?(attribute.name.to_s) }
          return args if named.empty?

          attribute = named.sample(random: @random)
          args.merge(attribute.name.to_s => InvalidValueGenerator.corrupt(attribute, aggregate, random: @random))
        end

        def add_identity!(args, entry)
          aggregate = entry[:aggregate]
          parent_key = (aggregate.identified_by || :id).to_s

          if entry[:entity]
            parent_scalar = pick_known(aggregate.hecks_name)
            args[parent_key] = identity_shaped(aggregate, aggregate.identified_by, parent_scalar, aggregate)
            entity_key = (entry[:entity].identified_by || :id).to_s
            entity_scalar = pick_entity_known(aggregate.hecks_name, entry[:entity].hecks_name, parent_scalar)
            args[entity_key] = identity_shaped(entry[:entity], entry[:entity].identified_by, entity_scalar, aggregate)
          elsif entry[:command].creates?
            args[parent_key] ||= identity_shaped(aggregate, aggregate.identified_by, ValueGenerator.random_id(@random), aggregate)
          else
            scalar = pick_known(aggregate.hecks_name)
            args[parent_key] = identity_shaped(aggregate, aggregate.identified_by, scalar, aggregate)
          end
        end

        # A bare scalar id, shaped to match whatever `construct` itself
        # declares that identity field as. `Account::LedgerEntry` is addressed
        # by `sequence`, and `sequence` is declared as a value-object-typed
        # attribute (`LedgerSequence`), not a plain identifier — a fuzz run
        # that skipped this wrapping and dispatched a bare `"1"` is exactly
        # what surfaced a real cross-runtime gap (Ruby refuses a bare scalar
        # against a value-object-typed identity with TypeMismatch ; Rust
        # accepts it and answers NotFound instead — same input, two different
        # refusals). Left as a bare scalar when the construct declares no such
        # attribute at all — the default `:id` case, which really is untyped.
        def identity_shaped(construct, key, scalar, aggregate)
          return scalar unless key

          attribute = construct.attribute(key)
          return scalar unless attribute

          value_object = aggregate.value_object(attribute.type.to_s)
          return scalar unless value_object

          field = value_object.attributes.first
          return scalar unless field

          { field.name.to_s => coerce_scalar(field.type.to_s, scalar) }
        end

        def coerce_scalar(type_name, scalar)
          case type_name
          when "Integer" then scalar.to_i
          when "Float"   then scalar.to_f
          else scalar.to_s
          end
        end

        def symbolize(args) = args.transform_keys(&:to_sym)

        # A step the runtime declines is not a generator failure — it simply did
        # not take effect, so nothing is recorded and the sequence carries on. The
        # step still goes into the corpus, because a REFUSAL IS AN ANSWER and the
        # two runtimes have to word it identically.
        #
        # EvaluationError sits alongside the declared refusals deliberately : a
        # payload the interpreter cannot read is the domain declining it, and
        # bin/run already records exactly those in a corpus's refusals —
        # `positive? expects a number, got "lots"` is one of banking's. Anything
        # else still propagates and fails spec/fuzzing, which is what says the
        # generator built a step that breaks the interpreter for reasons that have
        # nothing to do with a cross-runtime disagreement.
        def safe_call
          yield
        rescue *Hecksagain::Runtime::DOMAIN_REFUSALS, Hecksagain::Bluebook::Expression::EvaluationError
          nil
        end
      end
    end
  end
end
