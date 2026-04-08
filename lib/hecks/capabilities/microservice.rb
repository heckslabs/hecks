# Hecks::Capabilities::Microservice
#
# Composite capability that bundles :http, :auth, :metrics, and
# :rate_limit for a production-ready microservice.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :microservice
#   end
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::Microservice
    #
    # Bundles http + auth + metrics + rate_limit into one capability.
    #
    module Microservice
      BUNDLED = %i[http auth metrics rate_limit].freeze

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

Hecks.register_capability(:microservice) { |runtime| Hecks::Capabilities::Microservice.apply(runtime) }
