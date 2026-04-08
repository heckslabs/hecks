# Hecks::AI::BluebookBuilder
#
# Walks the structured JSON returned by LlmClient and replays it through the
# Workshop API to build a valid domain. Delegates type resolution to TypeResolver.
# After building, calls workshop.validate to confirm the domain is well-formed.
#
# Handles: aggregates, attributes, references, value_objects, entities,
#          validations, policies, lifecycle states, and lifecycle transitions.
#
#   json = { domain_name: "Banking", aggregates: [...] }
#   builder = Hecks::AI::BluebookBuilder.new(json)
#   workshop = builder.build   # => Hecks::Workshop
#   dsl = workshop.to_dsl      # => "Hecks.domain \"Banking\" do ..."
#
module Hecks
  module AI
    class BluebookBuilder
      # Initializes with the structured JSON hash from LlmClient.
      #
      # @param domain_json [Hash] structured domain definition with :domain_name and :aggregates
      def initialize(domain_json)
        @domain_json = domain_json
      end

      # Builds and returns a validated Workshop from the domain JSON.
      #
      # @return [Hecks::Workshop] the populated workshop
      # @raise [RuntimeError] if the domain fails validation
      def build
        domain_name = @domain_json[:domain_name] || @domain_json["domain_name"]
        raise "domain_name is required in domain JSON" unless domain_name

        @workshop = Hecks.workshop(domain_name)

        aggregates = @domain_json[:aggregates] || @domain_json["aggregates"] || []
        aggregates.each { |agg_json| build_aggregate(agg_json) }

        validate!
        @workshop
      end

      private

      def build_aggregate(agg_json)
        name = agg_json[:name] || agg_json["name"]
        return unless name

        handle = @workshop.aggregate(name)

        attrs      = agg_json[:attributes]      || agg_json["attributes"]      || []
        refs       = agg_json[:references]      || agg_json["references"]      || []
        vos        = agg_json[:value_objects]   || agg_json["value_objects"]   || []
        entities   = agg_json[:entities]        || agg_json["entities"]        || []
        validations = agg_json[:validations]    || agg_json["validations"]     || []
        policies   = agg_json[:policies]        || agg_json["policies"]        || []
        commands   = agg_json[:commands]        || agg_json["commands"]        || []
        lifecycle  = agg_json[:lifecycle]       || agg_json["lifecycle"]

        attrs.each     { |a| apply_attribute(handle, a) }
        refs.each      { |r| apply_reference(handle, r) }
        vos.each       { |v| apply_value_object(handle, v) }
        entities.each  { |e| apply_entity(handle, e) }
        validations.each { |v| apply_validation(handle, v) }
        policies.each  { |p| apply_policy(handle, p) }
        commands.each  { |c| apply_command(handle, c) }
        apply_lifecycle(handle, lifecycle) if lifecycle
      end

      def apply_attribute(handle, attr)
        name     = sym(attr[:name] || attr["name"])
        type_str = attr[:type] || attr["type"] || "String"
        return unless name

        if TypeResolver.reference_type?(type_str)
          handle.reference_to(TypeResolver.reference_target(type_str))
        else
          handle.attr(name, TypeResolver.resolve(type_str))
        end
      end

      def apply_reference(handle, ref)
        target = ref[:target] || ref["target"] || ref[:name] || ref["name"]
        handle.reference_to(target) if target
      end

      def apply_value_object(handle, vo)
        name  = vo[:name] || vo["name"]
        attrs = vo[:attributes] || vo["attributes"] || []
        return unless name

        resolved = attrs.map { |a| [sym(a[:name] || a["name"]), TypeResolver.resolve(a[:type] || a["type"])] }
        handle.value_object(name) do
          resolved.each { |n, t| attribute n, t }
        end
      end

      def apply_entity(handle, entity)
        name  = entity[:name] || entity["name"]
        attrs = entity[:attributes] || entity["attributes"] || []
        return unless name

        resolved = attrs.map { |a| [sym(a[:name] || a["name"]), TypeResolver.resolve(a[:type] || a["type"])] }
        handle.entity(name) do
          resolved.each { |n, t| attribute n, t }
        end
      end

      def apply_validation(handle, v)
        field    = sym(v[:field] || v["field"])
        presence = v[:presence] || v["presence"]
        return unless field

        rules = {}
        rules[:presence] = true if presence
        handle.validation(field, rules) unless rules.empty?
      end

      def apply_policy(handle, pol)
        name     = pol[:name]     || pol["name"]
        on_event = pol[:on_event] || pol["on_event"]
        trigger  = pol[:trigger]  || pol["trigger"]
        return unless name && on_event && trigger

        evt, trig = on_event, trigger
        handle.policy(name) { on evt; trigger trig }
      end

      def apply_command(handle, cmd)
        name  = cmd[:name] || cmd["name"]
        attrs = cmd[:attributes] || cmd["attributes"] || []
        return unless name

        plain_attrs = attrs.reject { |a| TypeResolver.reference_type?(a[:type] || a["type"]) }
        ref_attrs   = attrs.select { |a| TypeResolver.reference_type?(a[:type] || a["type"]) }

        resolved    = plain_attrs.map { |a| [sym(a[:name] || a["name"]), TypeResolver.resolve(a[:type] || a["type"])] }
        ref_targets = ref_attrs.map   { |a| TypeResolver.reference_target(a[:type] || a["type"]) }

        handle.command(name) do
          resolved.each    { |n, t| attribute n, t }
          ref_targets.each { |t|   reference_to t }
        end
      end

      def apply_lifecycle(handle, lc)
        field     = lc[:field]    || lc["field"]
        default   = lc[:default]  || lc["default"]
        transitions = lc[:transitions] || lc["transitions"] || []
        return unless field && default

        handle.lifecycle(sym(field), default: default)
        transitions.each do |tr|
          cmd    = tr[:command]  || tr["command"]
          target = tr[:target]   || tr["target"]
          handle.transition(cmd => target) if cmd && target
        end
      end

      def validate!
        domain = @workshop.to_domain
        valid, errors = Hecks.validate(domain)
        raise "Domain validation failed:\n#{errors.map { |e| "  - #{e}" }.join("\n")}" unless valid
      end

      def sym(val)
        val&.to_sym
      end
    end
  end
end
