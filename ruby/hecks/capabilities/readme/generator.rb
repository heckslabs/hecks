# Hecks::Capabilities::Readme::Generator
#
# Builds HECKS_README.md content from the runtime's domain IR,
# hecksagon capabilities, and world config. Each capability that
# declared metadata via describe_capability gets a section.
#
#   gen = Generator.new(runtime)
#   gen.generate  # => "# MyApp\n\n..."
#
module Hecks
  module Capabilities
    module Readme
      # Hecks::Capabilities::Readme::Generator
      #
      # Generates markdown documentation from domain IR + capability metadata.
      #
      class Generator
        def initialize(runtime)
          @runtime = runtime
          @domain = runtime.domain
          @hecksagon = runtime.instance_variable_get(:@hecksagon)
        end

        def generate
          sections = [
            title_section,
            capabilities_section,
            world_config_section,
            domain_section,
            commands_section,
            routing_section
          ]
          sections.compact.join("\n\n---\n\n")
        end

        private

        def title_section
          lines = ["# #{@domain.name}"]
          lines << "\n#{@domain.vision}" if @domain.respond_to?(:vision) && @domain.vision
          lines << "\nGenerated from Bluebook on boot. Do not edit."
          lines.join
        end

        def capabilities_section
          caps = @hecksagon&.capabilities || []
          return nil if caps.empty?
          lines = ["## Capabilities\n"]
          caps.each do |cap|
            meta = Hecks.capability_meta[cap]
            desc = meta ? meta[:description] : ""
            lines << "- **:#{cap}** — #{desc}"
          end
          lines.join("\n")
        end

        def world_config_section
          world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
          return nil unless world
          lines = ["## World Config\n", "```ruby", "Hecks.world \"#{world.name}\" do"]
          world.configs.each do |name, config|
            lines << "  #{name} do"
            config.each { |k, v| lines << "    #{k} #{v.inspect}" }
            lines << "  end"
          end
          lines << "end"
          lines << "```"

          # Add commented templates for unconfigured capabilities
          caps = @hecksagon&.capabilities || []
          configured = world.configs.keys.map(&:to_sym)
          unconfigured = caps.select { |c| Hecks.capability_config(c).any? } - configured
          unless unconfigured.empty?
            lines << ""
            lines << "### Available config (not yet configured)\n"
            unconfigured.each do |cap|
              lines << Hecks.capability_config_template(cap)
              lines << ""
            end
          end
          lines.join("\n")
        end

        def domain_section
          lines = ["## Bluebook: #{@domain.name}\n"]
          lines << "| Aggregate | Commands | Attributes |"
          lines << "|-----------|----------|------------|"
          @domain.aggregates.each do |agg|
            cmds = agg.commands.size
            attrs = agg.attributes.size
            lines << "| #{agg.name} | #{cmds} | #{attrs} |"
          end
          lines.join("\n")
        end

        def commands_section
          lines = ["## Commands\n"]
          @domain.aggregates.each do |agg|
            next if agg.commands.empty?
            lines << "### #{agg.name}\n"
            agg.commands.each do |cmd|
              attrs = cmd.attributes.map do |a|
                type = a.type.respond_to?(:name) ? a.type.name.split("::").last : a.type.to_s
                "#{a.name}: #{type}"
              end
              args = attrs.empty? ? "" : "(#{attrs.join(', ')})"
              lines << "- `#{cmd.name}#{args}`"
            end
            lines << ""
          end
          lines.join("\n")
        end

        def routing_section
          return nil unless @runtime.respond_to?(:client_commands)
          router = @runtime.client_commands
          lines = ["## Command Routing\n"]
          lines << "| Aggregate | Runs on |"
          lines << "|-----------|---------|"
          router.routing_table.each do |name, side|
            emoji = side == :client ? "browser" : "server"
            lines << "| #{name} | #{emoji} |"
          end
          lines.join("\n")
        end
      end
    end
  end
end
