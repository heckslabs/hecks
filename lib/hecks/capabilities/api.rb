# Hecks::Capabilities::Api
#
# Composite capability that bundles :http, :auth, and :rate_limit
# into a production-ready REST API stack.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :api
#   end
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::Api
    #
    # Bundles http + auth + rate_limit into one capability.
    #
    module Api
      BUNDLED = %i[http auth rate_limit].freeze

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

Hecks.register_capability(:api) { |runtime| Hecks::Capabilities::Api.apply(runtime) }
