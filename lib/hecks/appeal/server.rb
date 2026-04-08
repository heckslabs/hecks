# Hecks::Appeal::Server
#
# Entry point for the HecksAppeal IDE. Boots the IDE server with
# one or more Hecks projects and opens the browser interface.
#
#   ruby lib/hecks/appeal/server.rb                    # opens current dir
#   ruby lib/hecks/appeal/server.rb /path/to/project   # opens specific project
#
require "hecks"
require_relative "domain_bridge"
require_relative "ide_server"

module Hecks
  module Appeal
    class Server
      APPEAL_DIR = File.expand_path("..", __dir__.sub(/appeal$/, "appeal"))

      def self.compile_css
        input = File.join(__dir__, "assets", "css", "app.css")
        output = File.join(__dir__, "assets", "css", "tailwind.css")
        content = [
          File.join(__dir__, "views", "**", "*.html"),
          File.join(__dir__, "assets", "js", "**", "*.js")
        ].join(",")
        Process.spawn("tailwindcss", "-i", input, "-o", output,
                      "--content", content, "--minify", "--watch",
                      out: File::NULL, err: File::NULL)
      end

      def self.run(argv = ARGV)
        bridge = DomainBridge.new

        if argv.empty?
          bridge.discover(Dir.pwd).each { |path| bridge.open_project(path) }
        else
          argv.each do |path|
            expanded = File.expand_path(path)
            if File.directory?(File.join(expanded, "hecks"))
              bridge.open_project(expanded)
            else
              bridge.discover(expanded).each { |p| bridge.open_project(p) }
            end
          end
        end

        # Boot the Appeal chapter's own domain for IDE capabilities
        appeal_dir = File.expand_path("../chapters/appeal", __dir__)
        runtimes = boot_appeal(appeal_dir)

        compile_css

        server = IdeServer.new(bridge, runtimes)
        server.run
      end

      def self.boot_appeal(dir)
        Hecks.load_bluebook(
          Hecks::Chapters::Appeal.definition,
          skip_validation: true,
          source_dir: dir
        )
        domain = Hecks::Chapters::Appeal.definition

        # Set root before Runtime.new so capabilities resolve paths correctly
        appeal_root = File.expand_path("../appeal", __dir__)
        runtime = Hecks::Runtime.new(domain) do
          @root = appeal_root
          define_singleton_method(:root) { @root }
        end

        # Wire the hecksagon's adapter (sqlite) if declared
        hecksagon = runtime.instance_variable_get(:@hecksagon)
        if hecksagon&.persistence
          adapter_type = hecksagon.persistence[:type]
          hook = Hecks.extension_registry[adapter_type]
          mod = Object.const_get("HecksAppealBluebook")
          hook.call(mod, domain, runtime) if hook
        end

        [runtime]
      rescue => e
        $stderr.puts "[Appeal] Boot failed: #{e.message}"
        $stderr.puts e.backtrace&.first(3)&.join("\n")
        []
      end
    end
  end
end
