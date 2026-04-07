# GoHecks::PolicyGenerator
#
# Generates Go reactive policy structs. Policies subscribe to events
# and trigger commands. The event bus wires them at boot.
#
module GoHecks
  class PolicyGenerator
    include GoUtils

    def initialize(policy, aggregate_name: nil, domain: nil, package:)
      @policy = policy
      @agg_name = aggregate_name
      @domain = domain
      @package = package
    end

    def generate
      lines = []
      lines << "package #{@package}"
      lines << ""

      lines << "// #{@policy.name} reacts to #{@policy.event_name}"
      if @policy.respond_to?(:trigger_command) && @policy.trigger_command
        lines << "// and triggers #{@policy.trigger_command}"
      end
      lines << ""

      lines << "type #{@policy.name} struct {}"
      lines << ""
      lines << "func (p #{@policy.name}) EventName() string { return \"#{@policy.event_name}\" }"
      lines << ""

      if @policy.respond_to?(:trigger_command) && @policy.trigger_command
        trigger = @policy.trigger_command
        trigger_agg = find_trigger_aggregate

        # Check if the event type exists in this domain
        event_exists = @domain && @domain.aggregates.any? { |a| a.events.any? { |e| e.name == @policy.event_name } }

        # Look up trigger command to validate attribute mappings
        trigger_cmd = @domain&.aggregates&.flat_map(&:commands)&.find { |c| c.name == trigger }
        trigger_attrs = trigger_cmd ? trigger_cmd.attributes.map { |a| a.name.to_s } : []
        has_valid_map = @policy.respond_to?(:attribute_map) && @policy.attribute_map && !@policy.attribute_map.empty? &&
          @policy.attribute_map.any? { |to, _| trigger_attrs.include?(to.to_s) }

        if trigger_agg && event_exists
          lines << "func (p #{@policy.name}) Execute(event interface{}, #{GoUtils.camel_case(trigger_agg)}Repo #{trigger_agg}Repository) error {"
          if has_valid_map
            lines << "\te, ok := event.(*#{@policy.event_name})"
            lines << "\tif !ok { return nil }"
          end

          if has_valid_map
            valid_mappings = @policy.attribute_map.select { |to, _| trigger_attrs.include?(to.to_s) }
            lines << "\tcmd := #{trigger}{"
            valid_mappings.each do |to_attr, from_attr|
              lines << "\t\t#{GoUtils.pascal_case(to_attr)}: e.#{GoUtils.pascal_case(from_attr)},"
            end
            lines << "\t}"
          else
            lines << "\tcmd := #{trigger}{}"
          end

          lines << "\t_, _, err := cmd.Execute(#{GoUtils.camel_case(trigger_agg)}Repo)"
          lines << "\treturn err"
          lines << "}"
        else
          lines << "func (p #{@policy.name}) Execute(event interface{}) {"
          lines << "\t// trigger aggregate not found for #{trigger}"
          lines << "}"
        end
      else
        lines << "func (p #{@policy.name}) Execute(event interface{}) {"
        lines << "\t// guard policy"
        lines << "}"
      end

      lines.join("\n") + "\n"
    end

    private

    def find_trigger_aggregate
      return nil unless @domain && @policy.respond_to?(:trigger_command)
      @domain.aggregates.each do |agg|
        return agg.name if agg.commands.any? { |c| c.name == @policy.trigger_command }
      end
      nil
    end
  end
end
