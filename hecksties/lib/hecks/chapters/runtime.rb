# Hecks::Chapters::Runtime
#
# Self-describing domain definition for the Runtime chapter. The boot,
# event bus, command bus, repository, and configuration subsystems model
# themselves as a domain with cross-cutting policies.
#
#   domain = Hecks::Chapters::Runtime.definition
#   domain.aggregates.map(&:name)
#   # => ["Runtime", "EventBus", "CommandBus", "Repository", "Configuration"]
#
module Hecks
  module Chapters
    module Runtime
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Runtime").tap { |b|
          b.instance_eval do
            aggregate "Runtime" do
              attribute :domain_name, String
              attribute :adapter, String

              command "Boot" do
                attribute :directory, String
                attribute :adapter, String
              end

              command "LoadDomain" do
                attribute :domain_id, String
              end

              command "SwapAdapter" do
                attribute :runtime_id, String
                attribute :aggregate_name, String
                attribute :adapter, String
              end
            end

            aggregate "EventBus" do
              attribute :name, String

              command "PublishEvent" do
                attribute :event_name, String
              end

              command "SubscribeEvent" do
                attribute :event_name, String
              end
            end

            aggregate "CommandBus" do
              attribute :name, String

              command "DispatchCommand" do
                attribute :command_name, String
              end
            end

            aggregate "Repository" do
              attribute :aggregate_name, String
              attribute :adapter_type, String

              command "SaveAggregate" do
                attribute :aggregate_id, String
              end

              command "FindAggregate" do
                attribute :aggregate_id, String
              end

              command "DeleteAggregate" do
                attribute :aggregate_id, String
              end
            end

            aggregate "Configuration" do
              attribute :adapter_type, String

              command "Configure" do
                attribute :adapter_type, String
              end

              command "RegisterExtension" do
                attribute :name, String
              end

              command "RegisterCapability" do
                attribute :name, String
              end
            end

            policy "WireExtensions" do
              on "Booted"
              trigger "RegisterExtension"
            end

            policy "WirePolicies" do
              on "LoadedDomain"
              trigger "SubscribeEvent"
            end
          end
        }.build
      end
    end
  end
end
