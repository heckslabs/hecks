require_relative "../../bluebook/expression/resolver"
require_relative "../invalid_value_generator"
require_relative "../value_generator"
require_relative "../../runtime/errors"
require_relative "../../runtime/value"
require_relative "../../naming"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Turn a picked entry into a corpus step: generate its arguments,
      # occasionally malform exactly one of them, shape its identity, and
      # dispatch it for real.
      module StepBuilder
        private

        def build_query_step(runtime, entry)
          args = args_for(entry[:query].attributes, entry[:aggregate])
          bind_to_written_row!(args, entry)
          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        # A report ask. Its only argument is `reference_name`, on a rooted model.
        # The id stays a bare scalar: `ReadModelInterpreter#refuse_object_reference`
        # rejects a wrapped identity.
        def build_read_model_step(runtime, entry)
          model = entry[:model]
          args  = model.reference_target.nil? ? {} : { model.reference_name.to_s => pick_known(model.reference_target) }

          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        # The adversarial mutation happens here, after the args and identity are
        # built and before the one inline dispatch, so the dispatch, the corpus
        # step and both replay engines all see the same mutated payload.
        #
        # The caller draw and then the dry-run coin follow the mutation. The order
        # is part of the seed contract; both draw nothing when off.
        def build_command_step(runtime, catalog, entry)
          args = args_for(entry[:command].attributes, entry[:aggregate])
          add_identity!(args, entry)
          steer_grant!(args, entry, catalog)
          mutations = adversarial_mutations!(args, entry, catalog)
          caller, caller_note = caller_draw!(entry, catalog)
          mutations << caller_note if caller_note
          @state_before = state_before(runtime, entry, args)

          step =
            if dry_run_draw?
              safe_call { as_caller(caller) { runtime.dry_run?(entry[:verb], **symbolize(args)) } }
              { "dry_run" => entry[:verb], "args" => args }
            else
              outcome = safe_call { as_caller(caller) { runtime.dispatch_flat(entry[:verb], symbolize(args)) } }
              if outcome
                record_outcome(catalog, entry, args)
                harvest_written_rows(runtime, catalog)
                @event_count += outcome.events.length
              end
              { "verb" => entry[:verb], "args" => args }
            end
          step.merge!(caller) if caller
          step["adversarial"] = mutations unless mutations.empty?
          step
        end

        # Draws nothing when the fraction is zero, like `adversarial?`.
        def dry_run_draw? = @dry_run.positive? && @random.rand < @dry_run

        # Runs the block under `Hecks.as_caller`, the binding `Fuzzing::Replay` makes
        # from the step's keys, or yields bare when there is no caller.
        def as_caller(caller, &)
          return yield unless caller

          Hecks.as_caller(role: caller["role"], actor_id: caller["actor_id"], &)
        end

        def args_for(attributes, aggregate)
          args = attributes.each_with_object({}) do |attribute, built|
            # Omitting an optional argument is an ordinary payload, not a malformation
            # (see OPTIONAL_OMITTED_PROBABILITY).
            next if attribute.optional? && @random.rand < SequenceGenerator::OPTIONAL_OMITTED_PROBABILITY

            if attribute.list?
              value = list_value_for(attribute, aggregate)
              # `list_value_for` answers nil for a list of entities (those are
              # populated by per-element append commands), so the step skips it.
              next if value.nil?

              built[attribute.name.to_s] = value
            else
              built[attribute.name.to_s] = ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids)
            end
          end

          malform(args, attributes, aggregate)
        end

        # An array of 0-3 independently generated elements shaped like the bare
        # element type. `nil`, not `[]`, when the element type is not a value object.
        def list_value_for(attribute, aggregate)
          value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
          return nil unless value_object

          Array.new(@random.rand(0..3)) { ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids) }
        end

        # At most one malformation per step, so the check that fired is identifiable.
        # The rate stays low because refused steps reach no state.
        def malform(args, attributes, aggregate)
          return args if args.empty? || @random.rand >= MALFORMED_ARGUMENT_PROBABILITY

          case @random.rand(3)
          when 0 then corrupt_one(args, attributes, aggregate)
          when 1 then drop_one(args, aggregate)
          else        args.merge([InvalidValueGenerator.undeclared_argument(random: @random)].to_h)
          end
        end

        # Never drops the identity: an auto-minted id is unreproducible, so the
        # step's outcome could not be replayed.
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
            # One identity per hop, drawn from that hop's pool (`entity_pool_key`), as
            # flat args, which is what `EntityElement#locate_chain` reads.
            scalars = [parent_scalar]
            names   = []
            entry[:chain].each do |piece|
              names << piece.hecks_name
              scalar = pick_entity_known(entity_pool_key(aggregate.hecks_name, names, scalars))
              args[(piece.identified_by || :id).to_s] = identity_shaped(piece, piece.identified_by, scalar, aggregate)
              scalars << scalar
            end
          elsif entry[:command].creates?
            # A composite identity's parts are already generated as the command's own
            # attributes; a synthetic `id` would be refused as an undeclared argument.
            unless composite_identity?(aggregate)
              args[parent_key] ||= identity_shaped(aggregate, aggregate.identified_by, ValueGenerator.random_id(@random),
                                                   aggregate)
            end
          else
            scalar = pick_known(aggregate.hecks_name)
            args[parent_key] = identity_shaped(aggregate, aggregate.identified_by, scalar, aggregate)
          end
        end

        # True only for a multi-field identity: `identified_by` is also nil for the
        # untyped default, whose parts are not in `args`.
        def composite_identity?(aggregate) = aggregate.identified_by.nil? && aggregate.identity_paths.size > 1

        # Shapes a bare scalar id like the construct's identity field. A
        # value-object-typed identity given a bare scalar is a TypeMismatch, so it
        # must be wrapped; the untyped default `:id` stays bare.
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

        # A declined step is not a generator failure: nothing is recorded, the
        # sequence carries on, and the step still enters the corpus as a refusal.
        #
        # EvaluationError counts as a refusal (an unreadable payload); any other
        # error propagates and fails spec/fuzzing.
        def safe_call
          result = yield
          @last_outcome = "ok"
          result
        rescue *Hecks::Runtime::DOMAIN_REFUSALS, Hecks::Bluebook::Expression::EvaluationError => e
          @last_outcome = e.class.name.split("::").last
          nil
        end

        # The addressed aggregate's lifecycle value before this dispatch, or
        # `exists`/`absent`; `?` when a mutation mangled the identity. Draws nothing from the RNG.
        def state_before(runtime, entry, args)
          aggregate = entry[:aggregate]
          symbolic  = symbolize(args)
          id = Runtime::Identity.of(aggregate, symbolic) || Runtime::Identity.from(aggregate, symbolic, :id)
          return "absent" unless id

          record = runtime.registry.repository(entry[:verb].split("::").first, aggregate).find(id)
          return "absent" unless record

          lifecycle = aggregate.lifecycle
          return "exists" unless lifecycle

          key = record.state.key?(lifecycle.field) ? lifecycle.field : lifecycle.field.to_s
          record.state[key].to_s
        rescue StandardError
          "?"
        end
      end
    end
  end
end
