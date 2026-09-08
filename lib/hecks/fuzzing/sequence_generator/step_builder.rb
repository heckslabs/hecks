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
          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        # A REPORT ASK — the bare domain form `entry[:verb]` already carries
        # ("Domain.report_name", no "::"), so `Dispatcher#query` routes it
        # to the read model rather than an aggregate query. A `ReadModel`
        # has no declared `.attributes` the way a `Query` does — its own
        # argument surface is exactly ONE key, `reference_name`, and ONLY
        # for a rooted model (`read_model_actionable?` already gated a
        # rootless one straight into eligibility with nothing to supply).
        # A BARE scalar, not `identity_shaped` — `ReadModelInterpreter#
        # refuse_object_reference` explicitly REJECTS a Hash/Value offered
        # here (this is the one place in the whole generator where the
        # subject's own identity must NOT be wrapped the way a command
        # argument's would be).
        def build_read_model_step(runtime, entry)
          model = entry[:model]
          args  = model.reference_target.nil? ? {} : { model.reference_name.to_s => pick_known(model.reference_target) }

          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        def build_command_step(runtime, catalog, entry)
          args = args_for(entry[:command].attributes, entry[:aggregate])
          add_identity!(args, entry)

          outcome = safe_call { runtime.dispatch(entry[:verb], **symbolize(args)) }
          if outcome
            record_outcome(catalog, entry, args)
            @event_count += outcome.events.length
          end
          { "verb" => entry[:verb], "args" => args }
        end

        def args_for(attributes, aggregate)
          args = attributes.each_with_object({}) do |attribute, built|
            # AN OPTIONAL ARGUMENT IS SOMETIMES NOT GIVEN, and that is an
            # ordinary payload rather than a damaged one — see
            # OPTIONAL_OMITTED_PROBABILITY for why this cannot live in
            # `malform` below and what it was costing while it did not
            # exist at all.
            next if attribute.optional? && @random.rand < SequenceGenerator::OPTIONAL_OMITTED_PROBABILITY

            if attribute.list?
              value = list_value_for(attribute, aggregate)
              # A list-of-ENTITY command attribute has no real example
              # anywhere in this repo's domains — every entity-owned list is
              # populated via a per-element append command instead, never a
              # whole-list command argument — so `list_value_for` (below)
              # answers `nil` for one rather than guessing at an entity's own
              # shape, and this step still skips it exactly as it always
              # has. A list-of-VALUE-OBJECT attribute (`ConsoleSettings::
              # Collection.ReplaceColumns`' own `columns`, `list_of(Column)`)
              # is the real, previously-unfuzzable case this now covers —
              # `sets :columns` imports the owner aggregate's own declared
              # `list_of` attribute onto the command verbatim (Command
              # Builder#resolve_bare_set!), so it is a required, ordinary
              # top-level argument like any other, not an entity mutation.
              next if value.nil?

              built[attribute.name.to_s] = value
            else
              built[attribute.name.to_s] = ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids)
            end
          end

          malform(args, attributes, aggregate)
        end

        # A `list_of` ATTRIBUTE'S OWN VALUE — an array of independently
        # generated elements, each shaped exactly the way a bare (non-list)
        # attribute of the SAME declared element type already is
        # (`ValueGenerator.value_for`), since `list_of(X)`'s own element
        # coercion is `X`'s ordinary shape repeated, not a different one
        # (`Attribute#type` is already unwrapped from `list_of(...)` at
        # declare time — the same fact `command_builder.rb`'s own comment
        # on `resolve_bare_set!` names). 0-3 elements — enough to exercise a
        # genuinely non-trivial replace without generating pathologically
        # large payloads every time. `nil`, not `[]`, when the element type
        # isn't a declared value object at all (an entity-typed list) — see
        # `args_for`'s own comment on why that case still skips rather than
        # guesses.
        def list_value_for(attribute, aggregate)
          value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
          return nil unless value_object

          Array.new(@random.rand(0..3)) { ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids) }
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

        # NEVER THE IDENTITY. A creating command with no id auto-mints one, and
        # a minted id is deliberately unreproducible — a random hex, never a
        # guessable counter — so dropping it manufactures a step whose outcome
        # cannot be replayed and says nothing about the runtime's behaviour.
        # Every step in the hand-written corpus
        # supplies an id for the same reason. Whether an auto-minted id OUGHT to
        # be reproducible is a real question, but it is not one a payload fuzzer
        # can ask.
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
            # A COMPOSITE IDENTITY (`identified_by` answering nil with MORE
            # THAN ONE declared path — Behaviour::Identified's own "a
            # composite has no single head" comment) supplies every one of
            # its parts as its own ordinary, individually-declared command
            # attribute already — `RoleAssignment::Assign` takes actor_id/
            # role_name/starts_at directly, `args_for` (above) already
            # generated all three. Forcing a synthetic top-level `id` here
            # too — this codebase's own fallback for the SINGLE-key and the
            # genuinely untyped (`identity_paths.empty?`, no `identified_by`
            # declared at all) cases — hands a composite creating command
            # an argument it never declared at all, refused every time as
            # unknown before this check existed (a creating `Assign`/`Grant`
            # step was never anything BUT refused). `identity_paths.empty?`
            # is the untyped default (falls all the way back to a minted
            # `:id` the runtime itself never declared as an attribute
            # either), which still needs exactly the old minting behavior.
            unless composite_identity?(aggregate)
              args[parent_key] ||= identity_shaped(aggregate, aggregate.identified_by, ValueGenerator.random_id(@random),
                                                   aggregate)
            end
          else
            scalar = pick_known(aggregate.hecks_name)
            args[parent_key] = identity_shaped(aggregate, aggregate.identified_by, scalar, aggregate)
          end
        end

        # TRUE ONLY FOR A GENUINE MULTI-FIELD IDENTITY — `identified_by`
        # returns nil both for a real composite (`identity_paths.size > 1`)
        # and for the untyped default with NO identity declared at all
        # (`identity_paths.size == 0`, Behaviour::Identified's own
        # `Array(@identified_by)` fallback) ; only the first of those two
        # has its own parts already sitting in `args` as real, individually-
        # generated command attributes.
        def composite_identity?(aggregate) = aggregate.identified_by.nil? && aggregate.identity_paths.size > 1

        # A bare scalar id, shaped to match whatever `construct` itself
        # declares that identity field as. `Account::LedgerEntry` is addressed
        # by `sequence`, and `sequence` is declared as a value-object-typed
        # attribute (`LedgerSequence`), not a plain identifier — a fuzz run
        # that skipped this wrapping and dispatched a bare `"1"` had every
        # such step refused at the type gate (a bare scalar against a
        # value-object-typed identity is a TypeMismatch, not a NotFound), so
        # the wrapping is what lets a fuzz step address the record at
        # all. Left as a bare scalar when the construct declares no such
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
        # step still goes into the corpus, because a REFUSAL IS AN ANSWER, and
        # its wording is pinned by the corpus.
        #
        # EvaluationError sits alongside the declared refusals deliberately : a
        # payload the interpreter cannot read is the domain declining it, and
        # bin/run already records exactly those in a corpus's refusals —
        # `positive? expects a number, got "lots"` is one of banking's. Anything
        # else still propagates and fails spec/fuzzing, which is what says the
        # generator built a step that breaks the interpreter for reasons that have
        # nothing to do with the domain declining a payload.
        def safe_call
          yield
        rescue *Hecks::Runtime::DOMAIN_REFUSALS, Hecks::Bluebook::Expression::EvaluationError
          nil
        end
      end
    end
  end
end
