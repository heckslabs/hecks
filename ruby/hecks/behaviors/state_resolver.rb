# Hecks::Behaviors::StateResolver
#
# Resolves the AggregateState a dispatch should land on, applies
# aggregate defaults and lifecycle defaults on first touch, and
# transitions the lifecycle field on commands that name a transition.
#
# Mirrors the Rust runtime's command_dispatch.rs decisions exactly:
#   - self-ref + id present     → load that record (404 if missing)
#   - self-ref + no id + Create → new state, is_new=true
#   - self-ref + no id + other  → missing-self-ref error
#   - no self-ref               → singleton (load if exists, else new)
#
# This file is internal to BehaviorRuntime — there's no public API to
# call directly. Extracted for the 200-LoC limit and to keep the
# runtime's dispatch loop readable.
require_relative "value"
require_relative "aggregate_state"
require_relative "interpreter"

module Hecks
  module Behaviors
    module StateResolver
      module_function

      CREATE_PREFIXES = %w[Create Add Place Register Open].freeze

      def resolve(rt, agg, cmd, attrs)
        self_ref = (cmd.references || []).find do |r|
          target = r.respond_to?(:target) ? r.target : r.type
          target == agg.name
        end
        if self_ref
          if (id_val = attrs[self_ref.name.to_s])
            id = id_val.to_display.to_s
            existing = rt.repositories[agg.name][id]
            return [existing, false] if existing
            raise "aggregate not found: #{id}"
          end
          if CREATE_PREFIXES.any? { |p| cmd.name.start_with?(p) }
            return [AggregateState.new(next_id(rt, agg.name)), true]
          end
          raise Interpreter::GivenFailed.new(
            "missing self-referencing id", "self-referencing id"
          )
        end
        id = next_id(rt, agg.name)
        if (existing = rt.repositories[agg.name][id])
          [existing, false]
        else
          [AggregateState.new(id), true]
        end
      end

      # Mirrors hecks_life/src/runtime/repository.rs Repository#next_id:
      # for singleton (no-self-ref) commands the heki adapter REUSES the
      # existing record's id rather than minting a fresh one. Without
      # this, every cascade-triggered policy command on a singleton
      # aggregate would resolve to a brand-new AggregateState with all
      # defaults, blanking the setup-chain state that downstream guards
      # depend on. Cascade `given` evaluation against integer fields
      # (e.g. sleep_cycle < sleep_total) then sees (0, 0) instead of
      # the actual (1, 8) and routes the wrong branch — Ilya P1 bug.
      def next_id(rt, agg_name)
        repo = rt.repositories[agg_name]
        return "1" if !repo || repo.empty?
        # Singleton: reuse the first existing key. Repos accumulate
        # entries only when commands carry a self-ref (Create-style),
        # so for non-self-ref commands there is at most one record and
        # this picks it correctly.
        repo.keys.first
      end

      def apply_aggregate_defaults(agg, state)
        (agg.attributes || []).each do |a|
          next if state.fields[a.name.to_s]
          if a.respond_to?(:default) && !a.default.nil?
            state.set(a.name, Value.from(a.default))
          elsif a.respond_to?(:type) && a.type.to_s == "list_of"
            state.set(a.name, Value.list([]))
          end
        end
      end

      def apply_lifecycle_default(agg, state)
        lifecycles(agg).each do |lc|
          if state.fields[lc.field.to_s].nil? && lc.respond_to?(:default) && lc.default
            state.set(lc.field, Value.from(lc.default))
          end
        end
      end

      def apply_lifecycle_transition(agg, cmd, state)
        lifecycles(agg).each do |lc|
          to_state = transition_to_state(lc, cmd.name)
          state.set(lc.field, Value.from(to_state)) if to_state
        end
      end

      def lifecycles(agg)
        if agg.respond_to?(:lifecycles) && agg.lifecycles
          agg.lifecycles
        elsif agg.respond_to?(:lifecycle) && agg.lifecycle
          [agg.lifecycle]
        else
          []
        end
      end

      def transition_to_state(lc, cmd_name)
        return nil unless lc.respond_to?(:transitions)
        # Ruby IR: Array<[name, StateTransition]>. Rust: Vec<Transition>.
        lc.transitions.each do |tr|
          if tr.is_a?(Array)
            name, st = tr
            next unless name.to_s == cmd_name.to_s
            return st.respond_to?(:target) ? st.target : st.to_state
          else
            next unless tr.respond_to?(:name) && tr.name.to_s == cmd_name.to_s
            return tr.respond_to?(:to_state) ? tr.to_state : tr.target
          end
        end
        nil
      end
    end
  end
end
