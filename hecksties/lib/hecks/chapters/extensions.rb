# Hecks::Chapters::Extensions
#
# Self-describing Bluebook chapter for the Extensions subsystem. Models
# the extension infrastructure as a domain: HTTP serving, auth, audit,
# PII, metrics, persistence, multi-tenancy, event queues, and
# cross-domain wiring.
#
#   domain = Hecks::Chapters::Extensions.definition
#   domain.aggregates.map(&:name)
#   # => ["HttpServer", "Auth", "AuditTrail", "PiiProtection", ...]
#
module Hecks
  module Chapters
    module Extensions
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Extensions").tap { |b|
          b.instance_eval do
            aggregate "HttpServer" do
              attribute :port, Integer
              attribute :rpc_enabled, :Boolean

              command "StartServer" do
                attribute :port, Integer
              end

              command "HandleRequest" do
                attribute :method, String
                attribute :path, String
              end

              command "GenerateOpenApi" do
                attribute :domain_name, String
              end
            end

            aggregate "Auth" do
              attribute :enforce, :Boolean

              command "Authenticate" do
                attribute :actor_role, String
              end

              command "Authorize" do
                attribute :command_name, String
                attribute :required_roles, String
              end

              command "RegisterSentinel"
            end

            aggregate "AuditTrail" do
              attribute :event_name, String
              attribute :actor, String
              attribute :timestamp, String

              command "RecordEvent" do
                attribute :event_name, String
              end

              command "ClearLog"
            end

            aggregate "PiiProtection" do
              attribute :field_name, String
              attribute :pii_marked, :Boolean

              command "MaskValue" do
                attribute :value, String
              end

              command "ErasePii" do
                attribute :entity_id, String
              end

              command "IntrospectFields" do
                attribute :aggregate_name, String
              end
            end

            aggregate "Metrics" do
              attribute :aggregate_name, String
              attribute :attribute_name, String

              command "CaptureChange" do
                attribute :aggregate_name, String
                attribute :attribute_name, String
              end

              command "RegisterSink" do
                attribute :sink_name, String
              end
            end

            aggregate "FilesystemStore" do
              attribute :data_dir, String

              command "SaveRecord" do
                attribute :aggregate_name, String
                attribute :record_id, String
              end

              command "LoadRecord" do
                attribute :record_id, String
              end

              command "DeleteRecord" do
                attribute :record_id, String
              end
            end

            aggregate "Tenancy" do
              attribute :strategy, String
              attribute :tenant_id, String

              command "SetTenant" do
                attribute :tenant_id, String
              end

              command "WrapRepository" do
                attribute :aggregate_name, String
              end
            end

            aggregate "CommandMiddleware" do
              attribute :middleware_name, String

              command "EnableLogging"

              command "EnableRetry" do
                attribute :max_attempts, Integer
                attribute :base_delay, Integer
              end

              command "EnableRateLimit" do
                attribute :limit, Integer
                attribute :period, Integer
              end

              command "EnableIdempotency" do
                attribute :ttl, Integer
              end

              command "EnableOutbox"
            end

            aggregate "EventQueue" do
              attribute :adapter_type, String

              command "PublishEvent" do
                attribute :event_name, String
                attribute :domain_name, String
              end

              command "ResolveAdapter" do
                attribute :adapter, String
              end
            end

          end
        }.build
      end
    end
  end
end
