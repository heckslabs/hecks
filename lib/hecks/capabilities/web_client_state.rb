# Hecks::Capabilities::WebClientState
#
# Optimistic client-side state management. Dispatches locally
# for instant UI, sends to server for persistence, deduplicates
# echoed events via correlation IDs. Uses localStorage as the
# client-side persistence adapter.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :web_client_state
#   end
#
require_relative "dsl"
require_relative "web_client_state/js_generator"

module Hecks
  module Capabilities
    module WebClientState
      def self.apply(runtime)
        generator = JsGenerator.new(runtime)
        js = generator.generate

        runtime.instance_variable_set(:@web_client_state_js, js)
        runtime.define_singleton_method(:web_client_state_js) { @web_client_state_js }

        mount_routes(runtime) if runtime.respond_to?(:static_assets_adapter)
      end

      def self.mount_routes(runtime)
        adapter = runtime.static_assets_adapter
        return unless adapter.respond_to?(:mount)
        js = runtime.web_client_state_js

        adapter.mount("/hecks/state.js") do |_req, res|
          res["Content-Type"] = "application/javascript"
          res.body = js
        end
      end
      private_class_method :mount_routes
    end
  end
end

Hecks.capability :web_client_state do
  description "Optimistic client state with localStorage + correlation dedup"
  on_apply do |runtime|
    Hecks::Capabilities::WebClientState.apply(runtime)
  end
end
