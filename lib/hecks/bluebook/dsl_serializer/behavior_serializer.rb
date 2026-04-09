module Hecks
  class DslSerializer
    # Hecks::DslSerializer::BehaviorSerializer
    #
    # Serializes commands, policies (aggregate-level and domain-level),
    # and event subscribers into DSL lines.
    #
    #   # Mixed into DslSerializer
    #   serialize_commands(agg.commands)
    #
    module BehaviorSerializer
      def serialize_commands(commands)
        commands.flat_map { |cmd| serialize_single_command(cmd) }
      end

      def serialize_policies(policies)
        policies.flat_map { |pol| serialize_aggregate_policy(pol) }
      end

      def serialize_subscribers(subscribers)
        subscribers.flat_map do |sub|
          async_opt = sub.async ? ", async: true" : ""
          lines = ["", "    on_event \"#{sub.event_name}\"#{async_opt} do |event|"]
          lines << "      #{Hecks::Utils.block_source(sub.block)}" if sub.block
          lines << "    end"
        end
      end

      def serialize_domain_policy(pol)
        lines = ["", "  policy \"#{pol.name}\" do"]
        lines << "    on \"#{pol.event_name}\""
        lines << "    trigger \"#{pol.trigger_command}\""
        lines << "    async true" if pol.async
        append_attribute_map(lines, pol, "    ")
        append_translate(lines, pol, "    ")
        append_condition(lines, pol, "    ")
        lines << "  end"
        lines
      end

      private

      def serialize_single_command(cmd)
        lines = ["", "    command \"#{cmd.name}\" do"]
        lines << "      description \"#{cmd.description}\"" if cmd.description
        append_emits(lines, cmd)
        lines.concat(serialize_attributes(cmd.attributes, "      "))
        lines.concat(serialize_references(cmd.references, "      "))
        cmd.read_models.each { |rm| lines << "      read_model \"#{rm.name}\"" }
        cmd.external_systems.each { |ext| lines << "      external \"#{ext.name}\"" }
        cmd.actors.each { |act| lines << "      actor \"#{act.name}\"" }
        lines << "    end"
      end

      def serialize_aggregate_policy(pol)
        lines = ["", "    policy \"#{pol.name}\" do"]
        lines << "      description \"#{pol.description}\"" if pol.description
        lines << "      on \"#{pol.event_name}\""
        lines << "      trigger \"#{pol.trigger_command}\""
        lines << "      async true" if pol.async
        append_translate(lines, pol, "      ")
        append_condition(lines, pol, "      ")
        lines << "    end"
      end

      def append_emits(lines, cmd)
        return unless cmd.emits

        emits_names = Array(cmd.emits)
        lines << "      emits #{emits_names.map { |n| "\"#{n}\"" }.join(", ")}"
      end

      def append_attribute_map(lines, pol, indent)
        return unless pol.attribute_map.any?

        mapping = pol.attribute_map.map { |from, to| "#{from}: :#{to}" }.join(", ")
        lines << "#{indent}map #{mapping}"
      end

      def append_translate(lines, pol, indent)
        return unless pol.respond_to?(:translate) && pol.translate

        body = Hecks::Utils.block_source(pol.translate)
        lines << "#{indent}translate { |event| #{body} }"
      end

      def append_condition(lines, pol, indent)
        return unless pol.condition

        body = Hecks::Utils.block_source(pol.condition)
        lines << "#{indent}condition { |event| #{body} }"
      end
    end
  end
end
