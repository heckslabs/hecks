# Hecks::Behaviors::BehaviorRuntime
#
# Pure-memory runtime for behavioral tests. Mirrors
# hecks_life/src/runtime/mod.rs Runtime — no hecksagon, no adapters,
# no IO, no extensions. Just repositories (id → AggregateState),
# an event bus (ordered list of {name, payload}), and dispatch.
#
# Two dispatch entry points:
#   dispatch(name, attrs)          # cascades policies via PolicyDrain
#   dispatch_isolated(name, attrs) # skips policy drain (used by setups)
#
# Apply order mirrors Rust command_dispatch.rs:
#   defaults (if new) → givens → mutations → lifecycle transition
#   → auto-input copy (if new) → save → emit
#
#   rt = BehaviorRuntime.boot(domain)
#   result = rt.dispatch("CreatePizza", { "name" => Value.from("M") })
#   result.aggregate_id; result.aggregate_type
require_relative "value"
require_relative "aggregate_state"
require_relative "interpreter"
require_relative "policy_drain"
require_relative "state_resolver"

module Hecks
  module Behaviors
    class BehaviorRuntime
      DispatchResult = Struct.new(:aggregate_type, :aggregate_id)

      attr_reader :domain, :repositories, :event_bus
      attr_accessor :reacted_to, :current_dispatch_agg

      def self.boot(domain)
        new(domain)
      end

      def initialize(domain)
        @domain = domain
        @repositories = {}
        @event_bus = []
        @reacted_to = 0
        domain.aggregates.each { |agg| @repositories[agg.name] = {} }
      end

      def find(agg_name, id)
        repo = @repositories[agg_name]
        repo && repo[id.to_s]
      end

      def dispatch(name, attrs)
        # Snapshot the bus boundary so the policy drainer only processes
        # events fired BY this dispatch (and its cascade), not earlier
        # setup events. Mirrors Rust drain_policies which works on the
        # CommandResult.event directly, not the global bus.
        @reacted_to = @event_bus.length
        result = dispatch_isolated(name, attrs)
        PolicyDrain.new(self).drain
        result
      end

      def dispatch_isolated(name, attrs)
        agg, cmd = find_command(name)
        raise "no command #{name}" unless cmd

        attrs = normalize_attrs(attrs)
        state, is_new = StateResolver.resolve(self, agg, cmd, attrs)
        @current_dispatch_agg = agg.name

        if is_new
          StateResolver.apply_aggregate_defaults(agg, state)
          StateResolver.apply_lifecycle_default(agg, state)
        end

        Interpreter.check_givens(cmd, state, attrs)
        Interpreter.apply_mutations(cmd, state, attrs)
        StateResolver.apply_lifecycle_transition(agg, cmd, state)

        copy_auto_input(agg, cmd, state, attrs) if is_new

        @repositories[agg.name][state.id] = state
        publish_emit(cmd, state, attrs)
        DispatchResult.new(agg.name, state.id)
      end

      def resolve_query(name, _attrs)
        agg, q = find_query(name)
        return { "state" => [] } unless q
        # Naive: return all records of the owning aggregate. The Rust
        # runner is exactly this naive too — count_query_records only
        # cares about array vs object vs missing.
        records = (@repositories[agg.name] || {}).values.map do |s|
          s.fields.transform_values(&:to_display)
        end
        { "state" => records }
      end

      def find_command(name)
        @domain.aggregates.each do |agg|
          cmd = agg.commands.find { |c| c.name == name }
          return [agg, cmd] if cmd
        end
        [nil, nil]
      end

      def find_query(name)
        @domain.aggregates.each do |agg|
          next unless agg.respond_to?(:queries) && agg.queries
          q = agg.queries.find { |x| x.name.to_s == name.to_s }
          return [agg, q] if q
        end
        [nil, nil]
      end

      private

      def normalize_attrs(attrs)
        out = {}
        (attrs || {}).each { |k, v| out[k.to_s] = v.is_a?(Value) ? v : Value.from(v) }
        out
      end

      # Mirrors hecks_life/src/runtime/command_dispatch.rs auto-input:
      # for `is_new` states, copy any cmd attribute that names an
      # aggregate attribute into state. Lets `String :name` on a Create
      # command become `state.name = attrs[:name]` without an explicit
      # `then_set`.
      def copy_auto_input(agg, cmd, state, attrs)
        agg_attr_names = (agg.attributes || []).map { |a| a.name.to_s }
        (cmd.attributes || []).each do |ca|
          n = ca.name.to_s
          next unless agg_attr_names.include?(n)
          state.set(n, attrs[n]) if attrs.key?(n)
        end
      end

      def publish_emit(cmd, state, attrs)
        agg_type = @current_dispatch_agg
        events = if cmd.emits
                   cmd.emits.is_a?(Array) ? cmd.emits : [cmd.emits]
                 else
                   []
                 end
        events.each do |ev_name|
          payload = state.fields.transform_values(&:to_display).merge(
            attrs.transform_values(&:to_display),
          )
          @event_bus << {
            name: ev_name.to_s,
            payload: payload,
            aggregate_id: state.id,
            aggregate_type: agg_type,
          }
        end
      end
    end
  end
end
