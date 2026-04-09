# Hecks::Capabilities::ProjectDiscovery
#
# Discovers and boots Hecks projects from the filesystem.
# Scans directories for hecks/*.bluebook files, boots each
# project, and provides state serialization for connected clients.
#
#   Hecks.hecksagon "MyIDE" do
#     capabilities :project_discovery
#   end
#
require_relative "dsl"
require_relative "project_discovery/bridge"

module Hecks
  module Capabilities
    # Hecks::Capabilities::ProjectDiscovery
    #
    # Filesystem project discovery and domain state serialization.
    #
    module ProjectDiscovery
      def self.apply(runtime)
        bridge = Bridge.new
        runtime.instance_variable_set(:@project_bridge, bridge)
        runtime.define_singleton_method(:projects) { @project_bridge }
        bridge
      end
    end
  end
end

Hecks.capability :project_discovery do
  description "Discover and boot Hecks projects from the filesystem"
  direction :driving
  on_apply do |runtime|
    Hecks::Capabilities::ProjectDiscovery.apply(runtime)
  end
end
