# Hecks::Capabilities::Observable
#
# Composite capability that bundles :metrics and :audit for
# full production observability.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :observable
#   end
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::Observable
    #
    # Bundles metrics + audit into one capability.
    #
    module Observable
      BUNDLED = %i[metrics audit].freeze

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

Hecks.register_capability(:observable) { |runtime| Hecks::Capabilities::Observable.apply(runtime) }
