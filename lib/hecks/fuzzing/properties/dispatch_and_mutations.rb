module Hecks
  module Fuzzing
    module Properties
      # Property: a dry-run step leaves the event count and every instance unchanged.
      # Entries without before/after snapshots (hand-built histories) are skipped.
      module DryRuns
        # Checks that every dry-run step left neither the event count nor any
        # instance's state changed.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true if every dry-run trace shows no change; otherwise
        #   a semicolon-joined message naming each offending dry run
        def dry_runs_leave_no_trace(history)
          offenders = Array(history[:dry_run_traces]).filter_map do |entry|
            before = entry[:before]
            after  = entry[:after]
            next unless before && after

            traces = []
            traces << "events #{before[:events]} -> #{after[:events]}" unless before[:events] == after[:events]
            traces << "instances changed" unless before[:instances] == after[:instances]
            next if traces.empty?

            "dry run of #{entry[:verb]} (ok: #{entry[:ok]}) left a trace: #{traces.join(', ')}"
          end

          offenders.empty? || offenders.join("; ")
        end
      end

      # Properties: saga/policy dispatch args match their `with_spec`, and command
      # mutations match an independent recomputation.
      module DispatchAndMutations
        # Checks saga and policy dispatch args against an independent re-derivation of
        # `with_spec`. Re-deriving, not calling the interpreter again, keeps the check
        # from agreeing with itself. Args are compared as captured live, because a
        # saga's memory keeps changing across a run.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true if every saga and policy dispatch's own bound args
        #   match an independent re-derivation of their `with_spec`; otherwise a
        #   semicolon-joined message naming each offending dispatch
        def dispatch_binding_fidelity(history)
          saga_offenders = history.fetch(:saga_dispatches, []).filter_map do |entry|
            expected = resolve_dispatch_binding(entry)
            next if expected == entry[:args]

            "#{entry[:process_manager]}##{entry[:instance]} dispatching #{entry[:dispatch]} on #{entry[:on]} — " \
              "bound #{entry[:args].inspect}, but independently re-deriving with_spec's own resolution gives " \
              "#{expected.inspect}"
          end

          policy_offenders = history.fetch(:policy_dispatches, []).filter_map do |entry|
            expected = resolve_trigger_binding(entry)
            next if expected == entry[:args]

            "#{entry[:policy]} on #{entry[:on]} — bound #{entry[:args].inspect}, but independently re-deriving " \
              "with_spec's own resolution gives #{expected.inspect}"
          end

          offenders = saga_offenders + policy_offenders
          offenders.empty? || offenders.join("; ")
        end

        # Re-derives SagaInterpreter#dispatch_args: a literal, the correlation key,
        # the triggering event's payload, or else the saga's carried memory.
        def resolve_dispatch_binding(entry)
          entry[:with_spec].to_h do |key, value|
            resolved = if !value.is_a?(Symbol) then value
                       elsif value == entry[:correlation_head] then entry[:instance]
                       elsif entry[:event_payload].key?(value) then entry[:event_payload][value]
                       else entry[:memory][value]
                       end
            [key.to_sym, Runtime::Value.materialize(resolved)]
          end
        end

        # Re-derives PolicyInterpreter#trigger_args: a policy has no correlation or
        # memory, so the trigger payload is the only source.
        def resolve_trigger_binding(entry)
          entry[:with_spec].to_h do |key, value|
            resolved = value.is_a?(Symbol) ? entry[:payload][value] : value
            [key.to_sym, Runtime::Value.materialize(resolved)]
          end
        end

        # Ops with an independent recomputation here. `:increment` and `:decrement` are
        # left out: their value-object and overflow handling is a much larger reproduction.
        #
        # Only the entity-scoped applier (`EntityElement#apply_to_element`) is
        # reproduced, since replay captures mutation traces for entity-owned commands only.
        # `:set` needs its own recomputation because the self-consistency checks share the
        # same `step_apply_mutations` call and cannot see a wrong `:set` result.
        #
        # `:unrecomputable` (never a finding) marks a step whose fuzzer-malformed args do
        # not fit the op's contract.
        RECOMPUTABLE_MUTATION_OPS = %i[append remove multiply clamp set].freeze

        # Checks that every recomputable mutation an entity-owned command
        # applied landed on the same after-state an independent
        # recomputation of the same rule produces.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true if every recomputable mutation's after-state
        #   matches an independent recomputation; otherwise a semicolon-joined message
        #   naming each offending mutation
        def mutations_match_recompute(history)
          bluebooks = history.fetch(:bluebooks)

          offenders = history.fetch(:mutation_traces, []).flat_map do |entry|
            next [] unless entry[:after]

            command = command_for_verb(bluebooks, entry[:verb])
            next [] unless command

            aggregate = aggregate_for_verb(bluebooks, entry[:verb])
            next [] unless aggregate

            owner = owner_for_verb(bluebooks, entry[:verb]) || aggregate

            command.mutations.select { |m| RECOMPUTABLE_MUTATION_OPS.include?(m.op) }.filter_map do |mutation|
              expected = recompute_mutation(mutation, entry[:before][mutation.target], entry[:args], entry[:before],
                                            aggregate, command, owner)
              next if expected == :unrecomputable

              actual = entry[:after][mutation.target]
              next if symbolize_deep(expected) == symbolize_deep(actual)

              "#{entry[:verb]} — #{mutation.op} on #{mutation.target} — recomputing independently gives " \
                "#{expected.inspect}, but the real dispatch left #{actual.inspect}"
            end
          end

          offenders.empty? || offenders.join("; ")
        end

        # Root aggregate for `verb`, derived from the verb alone because hand-built
        # entries may lack `:domain`/`:aggregate`. Value-object types resolve against
        # the root's namespace only.
        def aggregate_for_verb(bluebooks, verb)
          domain_name, aggregate_name, = Naming.split_verb(verb)
          return nil unless domain_name

          bluebooks[domain_name]&.aggregate(aggregate_name)
        end

        # The construct declaring `mutation.target`: the root aggregate, or the owning
        # entity for a dot-shaped command. Attribute lookups must ask that construct,
        # as `EntityElement#locate_chain` does.
        def owner_for_verb(bluebooks, verb)
          domain_name, aggregate_name, command_path = Naming.split_verb(verb)
          return nil unless command_path

          aggregate = bluebooks[domain_name]&.aggregate(aggregate_name)
          return nil unless aggregate
          return aggregate unless command_path.include?(".")

          entity_name, = command_path.split(".", 2)
          aggregate.entities.find { |candidate| candidate.hecks_name == entity_name }
        end

        # Dispatches to the recompute rule for `mutation.op`.
        def recompute_mutation(mutation, current, args, before_scope, aggregate, command, owner = aggregate)
          case mutation.op
          when :append
            recompute_append(current, mutation.source, before_scope, args, aggregate, command, owner, mutation.target)
          when :remove   then recompute_remove(current, mutation.source, args)
          when :multiply then recompute_multiply(current, resolve_mutation_source(mutation.source, args))
          when :clamp    then recompute_clamp(current, mutation.source)
          when :set      then recompute_set(mutation.source, args, aggregate, owner, mutation.target)
          end
        end

        # Re-derives the `:set` branch of `EntityElement#apply_to_element`. The
        # attribute comes from `owner`, not the root aggregate, which would leave a
        # nested entity's value uncoerced and disagree with the real after-state.
        # Any raise means the raw material was wrong, so the result is `:unrecomputable`.
        def recompute_set(source, args, aggregate, owner, target)
          raw = resolve_mutation_source(source, args)
          attribute = owner&.attribute(target)
          coerced = attribute ? Runtime::Value.for_attribute(aggregate, attribute, raw) : raw
          Runtime::Value.materialize(coerced)
        rescue StandardError
          :unrecomputable
        end

        # Re-derives `EntityElement#appended_to_element`: each field resolves from a
        # caller arg (coerced as `Interpreting#coerce_declared_arguments` does) or from
        # the entity's current field (already materialized), then the element is appended.
        # A nested-entity element also gets its declared defaults.
        def recompute_append(current, source_map, before_scope, args, aggregate, command, owner = aggregate, target = nil)
          fields = source_map.transform_values do |source|
            resolve_mutation_append_field(source, before_scope, args, aggregate, command)
          end
          fill_recompute_declared_defaults(aggregate, owner, target, fields)
          Array(current) + [symbolize_deep(fields)]
        end

        # Fills defaults for a nested-entity element via `Instance.default_for`, which is
        # independently tested. No-op unless `target` names an entity under `owner`
        # (`owner.entities`, not `aggregate.entities`).
        #
        # A value-object element type (the more common shape: `list_of` a plain composite,
        # not a nested entity) defaults the other way real dispatch does — through
        # `Runtime::Value.apply_defaults`, the exact primitive `EntityElement#appended_to_
        # element`'s own `Value.build` call uses. Without this branch, a caller-omitted,
        # VO-declared `default:` field is left out of the recomputed element entirely,
        # disagreeing with real dispatch's fully-defaulted one.
        def fill_recompute_declared_defaults(aggregate, owner, target, fields)
          return fields unless target

          element_type = owner&.attribute(target)&.type
          return fields unless element_type

          entity = owner.entities.find { |piece| piece.hecks_name == element_type.to_s }
          if entity
            entity.attributes.each do |attribute|
              next if fields.key?(attribute.name)

              fields[attribute.name] = attribute.list? ? [] : Runtime::Instance.default_for(aggregate, attribute)
            end
            return fields
          end

          value_object = aggregate.value_object(element_type)
          return fields unless value_object

          Runtime::Value.apply_defaults(value_object, fields)
        end

        # Resolves one appended field's value from its declared source.
        def resolve_mutation_append_field(source, before_scope, args, aggregate, command)
          return source unless source.is_a?(Symbol)
          return before_scope[source] unless args.key?(source)

          coerce_recompute_append_arg(aggregate, command, source, args[source])
        end

        # Coerces a raw arg only when `source` is a declared attribute of the command,
        # as a real dispatch does. Materialized so the comparison is plain data on both sides.
        def coerce_recompute_append_arg(aggregate, command, source, raw)
          attribute = command.attribute(source)
          return raw unless attribute

          Runtime::Value.materialize(Runtime::Value.for_attribute(aggregate, attribute, raw, argument: true))
        end

        # Re-derives `MutationApplier#removed`: removes every value-equal element.
        # `Value.materialize` first: once `args` arrives normalized (replay.rb's
        # `build_mutation_trace`), a composite `remove:` source is already a built
        # `Runtime::Value` with its own declared defaults filled — comparing it
        # unmaterialized against `current`'s plain Hashes would never match, wrongly
        # keeping an element real dispatch correctly removed.
        def recompute_remove(current, source, args)
          target = symbolize_deep(Runtime::Value.materialize(resolve_mutation_source(source, args)))
          Array(current).reject { |element| symbolize_deep(element) == target }
        end

        # Re-derives `CommandRules::Arithmetic#multiply` on plain data: a Hash with one
        # numeric field scales that field, a bare Numeric scales itself. A nil
        # `current` is treated as 0.
        def recompute_multiply(current, amount)
          return :unrecomputable unless amount.is_a?(Numeric)

          current ||= 0
          if current.is_a?(Hash)
            field = current.keys.find { |f| current[f].is_a?(Numeric) }
            return :unrecomputable unless field

            current.merge(field => current[field] * amount)
          elsif current.is_a?(Numeric)
            current * amount
          else
            :unrecomputable
          end
        end

        # Re-derives `CommandRules::Arithmetic#clamp` like #recompute_multiply. The
        # source is always a literal `[min, max]`, never an argument reference.
        def recompute_clamp(current, bounds)
          return :unrecomputable unless bounds.is_a?(Array) && bounds.size == 2

          min, max = bounds
          current ||= 0
          if current.is_a?(Hash)
            field = current.keys.find { |f| current[f].is_a?(Numeric) }
            return :unrecomputable unless field

            current.merge(field => current[field].clamp(min, max))
          elsif current.is_a?(Numeric)
            current.clamp(min, max)
          else
            :unrecomputable
          end
        end

        # A mutation source is an argument name (Symbol) or a literal.
        def resolve_mutation_source(source, args)
          source.is_a?(Symbol) ? args[source] : source
        end

        # Symbolizes hash keys recursively. Generated args carry string keys while
        # materialized trace state carries symbols, and `Hash#==` would otherwise differ.
        def symbolize_deep(value)
          case value
          when Hash  then value.to_h { |key, val| [key.to_sym, symbolize_deep(val)] }
          when Array then value.map { |val| symbolize_deep(val) }
          else value
          end
        end
      end
    end
  end
end
