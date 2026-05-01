# Hecks::Behaviors::PolicyDrain
#
# Cascade engine. Mirrors hecks_life/src/runtime/mod.rs drain_policies +
# inject_refs: walks events that this dispatch produced, fires every
# matching policy's trigger command, and recurses. Policies on the
# recursion stack are blocked (cycle break, allows diamond fan-in).
#
# Cross-aggregate id propagation: when a policy's trigger has a
# reference whose target matches the upstream event's aggregate type,
# the upstream id is injected under that ref's name. Other refs fall
# back to "any existing record of that target type" (singleton).
# Without this, cross-aggregate cascades stop at the first hop.
#
#   PolicyDrain.new(rt).drain
require_relative "value"

module Hecks
  module Behaviors
    class PolicyDrain
      MAX_DEPTH = 64

      def initialize(rt)
        @rt = rt
        @stack = []
      end

      def drain(depth = 0)
        return if depth > MAX_DEPTH
        loop do
          break if @rt.reacted_to >= @rt.event_bus.length
          ev = @rt.event_bus[@rt.reacted_to]
          @rt.reacted_to = @rt.reacted_to + 1
          @rt.domain.policies.each do |p|
            on = policy_event(p)
            next unless on && on == ev[:name]
            next if @stack.include?(p.name)
            @stack.push(p.name)
            begin
              attrs = inject_refs(p.trigger_command, ev)
              @rt.dispatch_isolated(p.trigger_command, attrs)
              drain(depth + 1)
            rescue Interpreter::GivenFailed
              # gate failed — cascade halts here, mirrors Rust silent halt
            rescue StandardError
              # missing self-ref, etc. also halt silently
            ensure
              @stack.pop
            end
          end
        end
      end

      def policy_event(p)
        if p.respond_to?(:on_event) && (v = p.on_event)
          return v
        end
        p.respond_to?(:event_name) ? p.event_name : nil
      end

      # For each reference on the triggered command, inject an id under
      # its kwarg name when not already present:
      #   1. ref target == upstream event's aggregate type → upstream id
      #   2. ref target has any existing record (singleton) → that id
      def inject_refs(cmd_name, ev)
        attrs = {}
        upstream_type = ev[:aggregate_type]
        upstream_id   = ev[:aggregate_id]
        _, cmd = @rt.find_command(cmd_name)
        return attrs unless cmd
        (cmd.references || []).each do |r|
          target = r.respond_to?(:target) ? r.target : r.type
          name   = r.name.to_s
          if target.to_s == upstream_type.to_s && upstream_id
            attrs[name] = Value.from(upstream_id)
            next
          end
          repo = @rt.repositories[target.to_s]
          if repo && (existing = repo.values.first)
            attrs[name] = Value.from(existing.id)
          end
        end
        attrs
      end
    end
  end
end
