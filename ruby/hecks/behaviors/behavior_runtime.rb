# Hecks::Behaviors::BehaviorRuntime
#
# Pure-memory runtime for behavioral tests. Mirrors
# rust/src/runtime/mod.rs Runtime — no hecksagon, no adapters,
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
require_relative "cross_aggregate_gate"

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

        Interpreter.check_required(cmd, attrs)
        CrossAggregateGate.resolve(self, cmd, state, attrs)
        Interpreter.check_givens(cmd, state, attrs)
        Interpreter.apply_mutations(cmd, state, attrs)
        StateResolver.apply_lifecycle_transition(agg, cmd, state)
        # f4 — invariants on the RESULTING state reject like a failed given.
        Interpreter.check_invariants(agg, state, attrs)

        copy_auto_input(agg, cmd, state, attrs) if is_new

        @repositories[agg.name][state.id] = state
        publish_emit(cmd, state, attrs)
        DispatchResult.new(agg.name, state.id)
      end

      def resolve_query(name, attrs = {})
        agg, q = find_query(name)
        return { "state" => [] } unless q
        attrs = normalize_attrs(attrs)
        wheres = q.respond_to?(:wheres) ? (q.wheres || []) : []
        # Mirror rust runtime resolve_query : keep records matching ALL
        # where-clauses. A `:param` value reads attrs ; any other token is a
        # literal. Without this, a `where state: "tasked"` query returned
        # every record regardless of state.
        records = (@repositories[agg.name] || {}).values.select do |s|
          wheres.all? { |w| where_matches(s, w, attrs) }
        end.map { |s| s.fields.transform_values(&:to_display) }
        { "state" => records }
      end

      # Resolve a command by address. Mirrors rust/src/behaviors_runner.rs
      # find_command : accepts Context.Aggregate.Command, Aggregate.Command,
      # and bare Command. Qualified forms filter by aggregate (and context)
      # so colliding command names (Cancel on Sprint/Story/Task) resolve to
      # the intended aggregate rather than first-match-wins.
      # Resolve a command by address. Mirrors rust parse_fqn + behaviors_runner
      # find_command : accepts
      #   Domain::Aggregate.Command  (canonical FQN, e.g. policy triggers)
      #   Context.Aggregate.Command  (legacy 3-dot)
      #   Aggregate.Command          (runner FQN from the test's on:)
      #   Command                    (bare — first-match)
      # Qualified forms filter by aggregate so colliding command names resolve
      # to the intended aggregate. The `::` head split is what lets cascade
      # policy triggers ("Plan::Story.MarkReady") dispatch at all.
      def find_command(name)
        s = name.to_s
        unless s.include?(".")
          @domain.aggregates.each do |agg|
            cmd = agg.commands.find { |c| c.name.to_s == s }
            return [agg, cmd] if cmd
          end
          return [nil, nil]
        end
        head, _, cmd_name = s.rpartition(".")
        if head.include?("::")
          ctx, agg_name = head.split("::", 2)
        elsif head.include?(".")
          ctx, agg_name = head.split(".", 2)
        else
          ctx, agg_name = nil, head
        end
        # Strict : aggregate name (+ context when the IR carries one).
        @domain.aggregates.each do |agg|
          next unless agg.name.to_s == agg_name
          if ctx
            agg_ctx = agg.respond_to?(:context) ? agg.context.to_s : ""
            next unless agg_ctx == ctx
          end
          cmd = agg.commands.find { |c| c.name.to_s == cmd_name }
          return [agg, cmd] if cmd
        end
        # Lenient fallback : aggregate name only (Ruby IR may not set context).
        if ctx
          @domain.aggregates.each do |agg|
            next unless agg.name.to_s == agg_name
            cmd = agg.commands.find { |c| c.name.to_s == cmd_name }
            return [agg, cmd] if cmd
          end
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

      # Mirror rust where_matches / resolve_where_value / compare_strings.
      def where_matches(state, clause, attrs)
        target = resolve_where_value(clause.value.to_s, attrs)
        fld = state.fields[clause.field.to_s]
        actual = fld ? fld.to_display.to_s : ""
        case clause.op.to_s
        when "eq"  then actual == target
        when "ne"  then actual != target
        when "gt"  then compare_strings(actual, target) > 0
        when "gte" then compare_strings(actual, target) >= 0
        when "lt"  then compare_strings(actual, target) < 0
        when "lte" then compare_strings(actual, target) <= 0
        else true
        end
      end

      def resolve_where_value(value, attrs)
        return value unless value.start_with?(":")
        v = attrs[value[1..]]
        v.is_a?(Value) ? v.to_display.to_s : v.to_s
      end

      def compare_strings(a, b)
        ai = Integer(a, exception: false)
        bi = Integer(b, exception: false)
        return ai <=> bi if ai && bi
        a <=> b
      end

      def normalize_attrs(attrs)
        out = {}
        (attrs || {}).each { |k, v| out[k.to_s] = v.is_a?(Value) ? v : Value.from(v) }
        out
      end

      # Mirrors rust/src/runtime/command_dispatch.rs auto-input:
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
