require_relative "mutation_recompute"

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
          offenders = Array(history[:dry_run_traces]).filter_map { |entry| dry_run_offender(entry) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one dry run that left a trace, or nil.
        def dry_run_offender(entry)
          before = entry[:before]
          after  = entry[:after]
          return unless before && after

          traces = dry_run_changes(before, after)
          return if traces.empty?

          "dry run of #{entry[:verb]} (ok: #{entry[:ok]}) left a trace: #{traces.join(", ")}"
        end

        # What differs between a dry run's before and after snapshots.
        def dry_run_changes(before, after)
          traces = []
          traces << "events #{before[:events]} -> #{after[:events]}" unless before[:events] == after[:events]
          traces << "instances changed" unless before[:instances] == after[:instances]
          traces
        end
      end

      # Properties: saga/policy dispatch args match their `with_spec`, and command
      # mutations match an independent recomputation.
      module DispatchAndMutations
        include MutationRecompute

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
          offenders = saga_binding_offenders(history) + policy_binding_offenders(history)
          offenders.empty? || offenders.join("; ")
        end

        # One message per saga dispatch whose bound args differ from the re-derivation.
        def saga_binding_offenders(history)
          history.fetch(:saga_dispatches, []).filter_map do |entry|
            expected = resolve_dispatch_binding(entry)
            next if expected == entry[:args]

            "#{entry[:process_manager]}##{entry[:instance]} dispatching #{entry[:dispatch]} on #{entry[:on]} — " \
              "bound #{entry[:args].inspect}, but independently re-deriving with_spec's own resolution gives " \
              "#{expected.inspect}"
          end
        end

        # One message per policy dispatch whose bound args differ from the re-derivation.
        def policy_binding_offenders(history)
          history.fetch(:policy_dispatches, []).filter_map do |entry|
            expected = resolve_trigger_binding(entry)
            next if expected == entry[:args]

            "#{entry[:policy]} on #{entry[:on]} — bound #{entry[:args].inspect}, but independently re-deriving " \
              "with_spec's own resolution gives #{expected.inspect}"
          end
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
          offenders = history.fetch(:mutation_traces, []).flat_map { |entry| mutation_offenders(bluebooks, entry) }
          offenders.empty? || offenders.join("; ")
        end

        # One message per recomputable mutation of `entry` whose real after-state differs.
        def mutation_offenders(bluebooks, entry)
          return [] unless entry[:after]

          context = mutation_context(bluebooks, entry)
          return [] unless context

          recomputable = context.command.mutations.select { |m| RECOMPUTABLE_MUTATION_OPS.include?(m.op) }
          recomputable.filter_map { |mutation| mutation_offender(mutation, entry, context) }
        end

        # What recomputing `entry` needs, or nil when its verb names no command or aggregate.
        def mutation_context(bluebooks, entry)
          command = command_for_verb(bluebooks, entry[:verb])
          return unless command

          aggregate = aggregate_for_verb(bluebooks, entry[:verb])
          return unless aggregate

          owner = owner_for_verb(bluebooks, entry[:verb]) || aggregate
          MutationRecompute::Context.new(aggregate, command, owner, entry[:before],
                                         with_declared_defaults(command, entry[:args]))
        end

        # The message for one mutation whose recomputation disagrees with the real dispatch.
        def mutation_offender(mutation, entry, context)
          expected = recompute_mutation(mutation, entry[:before][mutation.target], context)
          return if expected == :unrecomputable

          actual = entry[:after][mutation.target]
          return if symbolize_deep(expected) == symbolize_deep(actual)

          "#{entry[:verb]} — #{mutation.op} on #{mutation.target} — recomputing independently gives " \
            "#{expected.inspect}, but the real dispatch left #{actual.inspect}"
        end

        # The arguments the command actually ran with: an argument the caller left out takes the
        # default its attribute declares, as dispatch fills it, so the recomputation starts from
        # the same facts.
        #
        # @param command [Object] the command the step dispatched
        # @param args [Hash] the arguments the step offered
        # @return [Hash] `args`, with each omitted defaulted argument filled
        def with_declared_defaults(command, args)
          command.attributes.each_with_object(args.dup) do |attribute, held|
            next if attribute.default.nil? || held.key?(attribute.name.to_sym) || held.key?(attribute.name.to_s)

            held[attribute.name.to_sym] = attribute.default
          end
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
      end
    end
  end
end
