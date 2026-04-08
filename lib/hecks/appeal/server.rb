# Hecks::Appeal::Server
#
# Entry point for the HecksAppeal IDE. Boots the Appeal runtime
# with all capabilities, discovers projects, and starts the server.
# All behavior comes from capabilities — no hand-rolled infrastructure.
#
#   hecks appeal                    # serve current directory
#   hecks appeal /path/to/project   # serve specific project
#
require "hecks"
require_relative "ide_server"

module Hecks
  module Appeal
    class Server
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
        runtimes = boot_appeal

        # Discover and open projects via the capability's bridge
        bridge = runtimes.first&.respond_to?(:projects) ? runtimes.first.projects : nil
        if bridge
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
        end

        compile_css

        server = IdeServer.new(bridge, runtimes)
        server.run
      end

      def self.boot_appeal
        appeal_dir = File.expand_path("../chapters/appeal", __dir__)
        Hecks.load_bluebook(
          Hecks::Chapters::Appeal.definition,
          source_dir: appeal_dir
        )
        domain = Hecks::Chapters::Appeal.definition
        appeal_root = File.expand_path("../appeal", __dir__)

        runtime = Hecks::Runtime.new(domain) do
          @root = appeal_root
          define_singleton_method(:root) { @root }
        end

        # Wire persistence if declared
        hecksagon = runtime.instance_variable_get(:@hecksagon)
        if hecksagon&.persistence
          hook = Hecks.extension_registry[hecksagon.persistence[:type]]
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
