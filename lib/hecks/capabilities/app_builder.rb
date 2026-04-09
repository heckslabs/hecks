# Hecks::Capabilities::AppBuilder
#
# AI agent that plans and builds domain features. Reads a feature
# description, plans domain additions via Claude, and writes
# .bluebook code to implement them.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :app_builder
#     Feature.plan_feature.app_builder
#     Feature.build_feature.app_builder
#   end
#
require_relative "dsl"
require_relative "app_builder/planner"
require_relative "app_builder/builder"
require_relative "app_builder/verifier"

module Hecks
  module Capabilities
    module AppBuilder
      def self.apply(runtime)
        planner = Planner.new(runtime)
        builder = Builder.new(runtime)
        verifier = Verifier.new(runtime)

        runtime.instance_variable_set(:@app_builder_planner, planner)
        runtime.instance_variable_set(:@app_builder_builder, builder)
        runtime.instance_variable_set(:@app_builder_verifier, verifier)
        runtime.define_singleton_method(:app_builder) { @app_builder_planner }

        wire_websocket(runtime, planner, builder, verifier)
      end

      def self.wire_websocket(runtime, planner, builder, verifier)
        return unless runtime.respond_to?(:websocket)
        port = runtime.websocket
        original = port.method(:handle_message)
        port.define_singleton_method(:handle_message) do |client, raw|
          msg = JSON.parse(raw, symbolize_names: true) rescue nil
          if msg && msg[:type] == "app_builder"
            result = case msg[:action]&.to_s
            when "plan"   then planner.plan(msg[:title], msg[:description])
            when "build"  then builder.build(msg[:additions])
            when "verify" then verifier.verify(msg[:additions])
            else { error: "Unknown action: #{msg[:action]}" }
            end
            port.send_json(client, { type: "app_builder_result", action: msg[:action], data: result })
          else
            original.call(client, raw)
          end
        end
      end
      private_class_method :wire_websocket
    end
  end
end

Hecks.capability :app_builder do
  description "AI agent that plans and builds domain features"
  on_apply do |runtime|
    Hecks::Capabilities::AppBuilder.apply(runtime)
  end
end
