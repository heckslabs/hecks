# Hecks::Workshop::Renderer
#
# Formats domain IR elements into human-readable lines for deep_inspect
# output. Each render method takes an IR node and returns a formatted
# string. Used by DeepInspect to convert Navigator walk results into
# printable output.
#
#   renderer = Renderer.new
#   renderer.render_attribute(attr, depth: 1)  # => "  name: String"
#   renderer.render_command(cmd, depth: 1)      # => "  CreatePizza"
#
module Hecks
  class Workshop
    class Renderer
      INDENT = "  "

      # Render any element by dispatching on its label.
      #
      # @param element [Object] the IR node
      # @param depth [Integer] indentation level
      # @param label [String] the node type label from Navigator
      # @return [String, nil] formatted line, or nil for section headers
      def render(element, depth:, label:)
        case label
        when "aggregate"     then render_aggregate(element, depth)
        when "attribute"     then render_attribute(element, depth)
        when "value_object"  then render_value_object(element, depth)
        when "entity"        then render_entity(element, depth)
        when "lifecycle"     then render_lifecycle(element, depth)
        when /^transition:/  then render_transition(element, depth, label)
        when "command"       then render_command(element, depth)
        when "param"         then render_param(element, depth)
        when "precondition"  then render_condition(element, depth, "pre")
        when "postcondition" then render_condition(element, depth, "post")
        when "emits"         then render_emits(element, depth)
        when "event"         then render_event(element, depth)
        when "field"         then render_field(element, depth)
        when "query"         then render_query(element, depth)
        when "validation"    then render_validation(element, depth)
        when "invariant"     then render_invariant(element, depth)
        when "policy"        then render_policy(element, depth)
        when "scope"         then render_scope(element, depth)
        when "specification" then render_specification(element, depth)
        when "subscriber"    then render_subscriber(element, depth)
        when "reference"     then render_reference(element, depth)
        end
      end

      private

      def indent(depth)
        INDENT * depth
      end

      def render_aggregate(agg, depth)
        "#{indent(depth)}#{agg.name}"
      end

      def render_attribute(attr, depth)
        "#{indent(depth)}#{attr.name}: #{Hecks::Utils.type_label(attr)}"
      end

      def render_value_object(vo, depth)
        "#{indent(depth)}[value_object] #{vo.name}"
      end

      def render_entity(ent, depth)
        "#{indent(depth)}[entity] #{ent.name}"
      end

      def render_lifecycle(lc, depth)
        states = lc.states.join(", ")
        "#{indent(depth)}[lifecycle] #{lc.field} (#{lc.default}) -> #{states}"
      end

      def render_transition(transition, depth, label)
        cmd = label.sub("transition:", "")
        target = transition.respond_to?(:target) ? transition.target : transition.to_s
        "#{indent(depth)}#{cmd} -> #{target}"
      end

      def render_command(cmd, depth)
        "#{indent(depth)}[command] #{cmd.name}"
      end

      def render_param(attr, depth)
        "#{indent(depth)}#{attr.name}: #{Hecks::Utils.type_label(attr)}"
      end

      def render_condition(condition, depth, kind)
        "#{indent(depth)}#{kind}condition: #{condition.message}"
      end

      def render_emits(event, depth)
        "#{indent(depth)}-> emits #{event.name}"
      end

      def render_event(event, depth)
        attrs = event.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
        "#{indent(depth)}[event] #{event.name}(#{attrs})"
      end

      def render_field(attr, depth)
        "#{indent(depth)}#{attr.name}: #{Hecks::Utils.type_label(attr)}"
      end

      def render_query(query, depth)
        "#{indent(depth)}[query] #{query.name}"
      end

      def render_validation(validation, depth)
        rules = validation.rules.map { |k, v| "#{k}: #{v}" }.join(", ")
        "#{indent(depth)}[validation] #{validation.field}: #{rules}"
      end

      def render_invariant(inv, depth)
        "#{indent(depth)}[invariant] #{inv.message}"
      end

      def render_policy(pol, depth)
        if pol.reactive?
          "#{indent(depth)}[policy] #{pol.name}: #{pol.event_name} -> #{pol.trigger_command}"
        else
          "#{indent(depth)}[policy] #{pol.name}: guard"
        end
      end

      def render_scope(scope, depth)
        "#{indent(depth)}[scope] #{scope.name}"
      end

      def render_specification(spec, depth)
        "#{indent(depth)}[spec] #{spec.name}"
      end

      def render_subscriber(sub, depth)
        async = sub.async ? " [async]" : ""
        "#{indent(depth)}[subscriber] on #{sub.event_name}#{async}"
      end

      def render_reference(ref, depth)
        kind = ref.respond_to?(:kind) && ref.kind ? " (#{ref.kind})" : ""
        "#{indent(depth)}[reference] -> #{ref.type}#{kind}"
      end
    end
  end
end
