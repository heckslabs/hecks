# HecksStatic::EntryPointGenerator::BootWiring
#
# Generates the boot method body: repository setup, command/query/persistence
# wiring, policy subscriptions, and constant hoisting. Mixed into
# EntryPointGenerator to keep the main file under 200 lines.
#
module HecksStatic
  class EntryPointGenerator < Hecks::Generator
    module BootWiring
      include HecksTemplating::NamingHelpers
      private

      def wire_commands(lines, agg)
        safe = domain_constant_name(agg.name)
        agg.commands.each do |cmd|
          method_name = domain_snake_name(cmd.name)
          lines << "      #{safe}::Commands::#{cmd.name}.repository = #{safe}.repository"
          lines << "      #{safe}::Commands::#{cmd.name}.event_bus = @event_bus"
          lines << "      #{safe}::Commands::#{cmd.name}.command_bus = @command_bus"
          lines << "      #{safe}::Commands::#{cmd.name}.aggregate_type = \"#{safe}\""
          lines << "      #{safe}.define_singleton_method(:#{method_name}) { |**attrs| #{safe}::Commands::#{cmd.name}.call(**attrs) }"
        end
      end

      def wire_queries(lines, agg)
        safe = domain_constant_name(agg.name)
        agg.queries.each do |query|
          method_name = domain_snake_name(query.name)
          lines << "      #{safe}::Queries::#{query.name}.repository = #{safe}.repository"
          lines << "      #{safe}.define_singleton_method(:#{method_name}) { |*args| #{safe}::Queries::#{query.name}.call(*args) }"
        end
      end

      def wire_persistence(lines, agg)
        safe = domain_constant_name(agg.name)
        lines << "      #{safe}.define_singleton_method(:find) { |id| repository.find(id) }"
        lines << "      #{safe}.define_singleton_method(:all) { repository.all }"
        lines << "      #{safe}.define_singleton_method(:count) { repository.count }"
        lines << "      #{safe}.define_singleton_method(:where) { |**conds| Runtime::QueryBuilder.new(repository).where(**conds) }"
      end

      def wire_policies(lines)
        @domain.aggregates.each do |agg|
          safe = domain_constant_name(agg.name)
          agg.policies.each do |pol|
            next if pol.guard?
            lines << "      @event_bus.subscribe(\"#{pol.event_name}\") { |event| #{safe}::Policies::#{pol.name}.new.call(event) }"
          end
        end
        @domain.policies.each do |pol|
          trigger_agg = @domain.aggregates.find { |agg| agg.commands.any? { |cmd| cmd.name == pol.trigger_command } }
          next unless trigger_agg
          safe = domain_constant_name(trigger_agg.name)
          if pol.attribute_map && !pol.attribute_map.empty?
            args = pol.attribute_map.map { |to, from| "#{to}: event.#{from}" }.join(", ")
            lines << "      @event_bus.subscribe(\"#{pol.event_name}\") { |event| #{safe}::Commands::#{pol.trigger_command}.call(#{args}) }"
          else
            lines << "      @event_bus.subscribe(\"#{pol.event_name}\") { |event| #{safe}::Commands::#{pol.trigger_command}.call }"
          end
        end
      end

      def build_validation_rules
        rules = {}
        @domain.aggregates.each do |agg|
          safe = domain_constant_name(agg.name)
          agg.commands.each do |cmd|
            cmd_snake = domain_snake_name(cmd.name)
            cmd_rules = {}
            cmd.attributes.each do |attr|
              validation = agg.validations.find { |val| val.field.to_s == attr.name.to_s }
              if validation
                cmd_rules[attr.name.to_s] = validation.rules.transform_keys(&:to_s)
                next
              end
              agg.value_objects.each do |vo|
                vo_attr = vo.attributes.find { |va| va.name.to_s == attr.name.to_s }
                if vo_attr
                  vo_rules = { "presence" => true }
                  vo.invariants.each do |inv|
                    vo_rules["positive"] = true if inv.message.to_s =~ /#{attr.name}.*positive|#{attr.name}.*> ?0/i
                  end
                  cmd_rules[attr.name.to_s] = vo_rules
                end
              end
            end
            rules["#{safe}/#{cmd_snake}"] = cmd_rules unless cmd_rules.empty?
          end
        end
        rules
      end
    end
  end
end
