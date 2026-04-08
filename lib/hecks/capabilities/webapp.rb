# Hecks::Capabilities::Webapp
#
# Composite capability that bundles :static_assets, :websocket, and
# :live_reload into a single declaration. Declare once in your
# hecksagon to get a full web app stack.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :webapp
#   end
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::Webapp
    #
    # Bundles static_assets + websocket + live_reload into one capability.
    #
    module Webapp
      BUNDLED = %i[project_discovery static_assets websocket live_reload client_commands readme].freeze

      # Apply all bundled capabilities to the runtime.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      def self.apply(runtime)
        BUNDLED.each do |cap|
          require "hecks/capabilities/#{cap}"
          hook = Hecks.capability_registry[cap]
          hook.call(runtime) if hook
        end
      end
    end
  end
end

Hecks.register_capability(:webapp) { |runtime| Hecks::Capabilities::Webapp.apply(runtime) }
