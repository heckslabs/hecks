# Hecks::Capabilities::Webstack
#
# Composite capability that bundles :webapp, :http, and :auth for
# a full web stack: static UI + REST API + authentication.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :webstack
#   end
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::Webstack
    #
    # Bundles webapp + http + auth into one capability.
    #
    module Webstack
      BUNDLED = %i[webapp http auth].freeze

      def self.apply(runtime)
        excluded = Hecks.instance_variable_get(:@_excluded_capabilities) || []
        BUNDLED.each do |cap|
          next if excluded.include?(cap)
          require "hecks/capabilities/#{cap}"
          hook = Hecks.capability_registry[cap]
          hook.call(runtime) if hook
        end
      end
    end
  end
end

Hecks.register_capability(:webstack) { |runtime| Hecks::Capabilities::Webstack.apply(runtime) }
