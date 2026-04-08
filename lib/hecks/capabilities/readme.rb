# Hecks::Capabilities::Readme
#
# Generates HECKS_README.md in the project directory on boot.
# Documents the domain's aggregates, commands, capabilities,
# world config, and routing decisions. Regenerated every boot
# so it's always in sync with the Bluebook.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :readme
#   end
#
# Generates: HECKS_README.md in Dir.pwd
#
require_relative "readme/generator"

module Hecks
  module Capabilities
    # Hecks::Capabilities::Readme
    #
    # Auto-generates project README from domain IR + capability metadata.
    #
    module Readme
      def self.apply(runtime)
        generator = Generator.new(runtime)
        output_dir = runtime.respond_to?(:root) ? runtime.root : Dir.pwd
        path = File.join(output_dir, "HECKS_README.md")
        File.write(path, generator.generate)
        $stderr.puts "[Readme] Generated #{path}"
      end
    end
  end
end

Hecks.register_capability(:readme) { |runtime| Hecks::Capabilities::Readme.apply(runtime) }

Hecks.describe_capability(:readme,
  description: "Auto-generate HECKS_README.md from domain IR on boot",
  config: {})
