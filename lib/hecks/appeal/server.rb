# Hecks::Appeal::Server
#
# Entry point for the HecksAppeal IDE. Boots the Appeal domain,
# discovers projects, starts the server. Everything is capabilities.
#
#   hecks appeal                    # serve current directory
#   hecks appeal /path/to/project   # serve specific project
#
require "hecks"
require_relative "ide_server"

module Hecks
  module Appeal
    class Server
      APPEAL_DIR = File.expand_path("../chapters/appeal", __dir__)
      APPEAL_ROOT = File.expand_path("../appeal", __dir__)

      def self.run(argv = ARGV)
        runtime = Hecks.boot(
          domain: Hecks::Chapters::Appeal.definition,
          root: APPEAL_ROOT,
          source_dir: APPEAL_DIR
        )
        runtime = [runtime] unless runtime.is_a?(Array)
        rt = runtime.first

        # Discover and load projects
        bridge = rt.respond_to?(:projects) ? rt.projects : nil
        load_projects(bridge, argv) if bridge

        IdeServer.new(bridge, runtime).run
      end

      def self.load_projects(bridge, argv)
        if argv.empty?
          bridge.discover(Dir.pwd).each { |p| bridge.open_project(p) }
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
    end
  end
end
