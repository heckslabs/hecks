# Hecks::Capabilities::AcceptanceTest
#
# Generates and serves a visual test runner from the domain IR.
# Dispatches every command, validates events fire, shows results
# in a floating overlay. Works for any app.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :acceptance_test
#   end
#
require_relative "dsl"
require_relative "acceptance_test/test_generator"

module Hecks
  module Capabilities
    module AcceptanceTest
      def self.apply(runtime)
        generator = TestGenerator.new(runtime)
        js = generator.generate

        runtime.instance_variable_set(:@acceptance_test_js, js)
        runtime.define_singleton_method(:acceptance_test_js) { @acceptance_test_js }

        mount_routes(runtime) if runtime.respond_to?(:static_assets_adapter)
      end

      def self.mount_routes(runtime)
        adapter = runtime.static_assets_adapter
        return unless adapter.respond_to?(:mount)
        js = runtime.acceptance_test_js

        adapter.mount("/hecks/tests.js") do |_req, res|
          res["Content-Type"] = "application/javascript"
          res.body = js
        end
      end
      private_class_method :mount_routes
    end
  end
end

Hecks.capability :acceptance_test do
  description "Visual acceptance test runner — dispatches every command, validates events"
  direction :driving
  on_apply do |runtime|
    Hecks::Capabilities::AcceptanceTest.apply(runtime)
  end
end
