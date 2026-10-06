module Hecks
  module Fuzzing
    module Replay
      # Snapshots the entity element a mutation step addresses before dispatch, and re-reads it
      # after, so the mutation can be diffed against an independent recomputation.
      module MutationTrace
        # The entity command a trace is about, and where it lives.
        Target = Struct.new(:domain, :aggregate_name, :command_name, :aggregate, :entity, :command)

        # The element a mutation step addresses, found in its parent's `list_of` attribute.
        Located = Struct.new(:parent_id, :list_attr, :wants, :element)

        module_function

        # Scoped to entity-dispatched commands only, the one place `append`/`remove`/
        # `multiply`/`clamp` act on an entity's own attributes. `nil` for anything out of
        # scope: an aggregate-level command, no mutations, or unresolvable identity args.
        def build(runtime, verb, args)
          target = target_for(runtime, verb)
          return nil unless target

          args = normalized_args(runtime, target, args)
          located = locate_element(runtime, target, args)
          return nil unless located

          { verb: verb, domain: target.domain, aggregate: target.aggregate_name, command: target.command_name,
            parent_id: located.parent_id, list_attr: located.list_attr.name, element_wants: located.wants,
            before: Runtime::Value.materialize(located.element), args: args }
        rescue StandardError
          nil
        end

        # The entity command `verb` names, when it declares mutations.
        def target_for(runtime, verb)
          domain_name, aggregate_name, command_name = Naming.split_verb(verb)
          return nil unless command_name&.include?(".")

          aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
          return nil unless aggregate

          entity, command = entity_command(aggregate, command_name)
          return nil unless mutates?(command)

          Target.new(domain_name, aggregate_name, command_name, aggregate, entity, command)
        end

        def mutates?(command) = command&.mutations&.any?

        # The entity and command a dotted `Entity.Command` path names under `aggregate`.
        def entity_command(aggregate, command_name)
          entity_name, entity_command_name = command_name.split(".", 2)
          entity = aggregate.entities.find { |candidate| candidate.hecks_name == entity_name }
          [entity, entity&.command(entity_command_name)]
        end

        # Same idiom as GuardCheck: real dispatch normalizes args
        # (step_normalize_args) before apply_mutations ever runs, coercing a declared
        # payload attribute into its command's shape — a composite argument's own
        # `Value.build` fills that shape's declared defaults along the way. Recomputing
        # a mutation against the raw fuzzed args instead would disagree with real
        # dispatch whenever a caller omitted a defaulted field, the same false-divergence
        # shape GuardCheck guards against for the guard check.
        def normalized_args(runtime, target, args)
          interpreter = Runtime::CommandInterpreter.new(runtime.registry, rules: Runtime::CommandRules.new(runtime.registry))
          interpreter.send(:normalize_args, target.aggregate, target.command, args)
        end

        # Finds the stored element the step's identity args address, or nil.
        def locate_element(runtime, target, args)
          parent_id = Replay.identity_for(target.aggregate, target.command, args)
          record = parent_id && runtime.registry.repository(target.domain, target.aggregate).find(parent_id)
          list_attr = record && list_attribute(target)
          wants = list_attr && element_wants(target, args)
          element = wants && find_element(record.state[list_attr.name], wants)
          element && Located.new(parent_id, list_attr, wants, element)
        end

        def list_attribute(target)
          target.aggregate.attributes.find { |a| a.list? && a.type.to_s == target.entity.hecks_name }
        end

        # The `[head, value]` identity pairs the args give for the entity, or nil when an
        # identity argument is missing.
        def element_wants(target, args)
          target.entity.identity_paths.map do |path|
            head = path.to_s.split(".").first.to_sym
            raw  = args[head]
            return nil if raw.nil?

            [head, Runtime::Value.for_attribute(target.aggregate, target.entity.attribute(head), raw)]
          end
        end

        def find_element(items, wants)
          Array(items).find { |element| wants.all? { |head, want| element[head] == want } }
        end

        # Re-locates the same element by identity, not position, since a mutation could
        # have changed the array's own length or order. `nil` if it vanished.
        def read_after(runtime, trace)
          record = parent_record(runtime, trace)
          return nil unless record

          element = find_element(record.state[trace[:list_attr]], trace[:element_wants])
          element && Runtime::Value.materialize(element)
        rescue StandardError
          nil
        end

        def parent_record(runtime, trace)
          aggregate = runtime.registry.bluebook(trace[:domain])&.aggregate(trace[:aggregate])
          aggregate && runtime.registry.repository(trace[:domain], aggregate).find(trace[:parent_id])
        end
      end
    end
  end
end
