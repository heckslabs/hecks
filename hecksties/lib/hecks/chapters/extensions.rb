# = Hecks::Chapters::Extensions
#
# Self-describing chapter for Hecks extension infrastructure. Covers
# all pluggable extensions: HTTP serving, persistence, auth, ACL,
# web explorer, tenancy, metrics, PII, and more.
#
#   domain = Hecks::Chapters::Extensions.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)
    # Hecks::Chapters::Extensions
    #
    # Bluebook chapter defining all pluggable Hecks extensions: HTTP serving, persistence, auth, tenancy, and more.
    #
    module Extensions
      def self.definition
        DSL::BluebookBuilder.new("Extensions").tap { |b|
          b.aggregate "Auth", "Actor-based authentication and authorization" do
            command("Authenticate") { attribute :actor, String }
            command("Authorize") { attribute :command_name, String; attribute :role, String }
          end

          b.aggregate "Audit", "Command execution audit trail" do
            command("Record") { attribute :command_name, String; attribute :actor, String }
          end

          b.aggregate "Bubble", "Anti-Corruption Layer for legacy system translation" do
            command("TranslateInbound") { attribute :legacy_data, String }
            command("TranslateOutbound") { attribute :domain_data, String }
          end

          b.aggregate "WebExplorer", "HTML UI for browsing aggregates and events" do
            command("Browse") { attribute :domain_name, String }
            command("RenderView") { attribute :template, String }
          end

          b.aggregate "Logging", "Structured logging for command dispatch" do
            command("Log") { attribute :message, String }
          end

          b.aggregate "Metrics", "Runtime metrics collection" do
            command("Record") { attribute :metric_name, String; attribute :value, Integer }
          end

          b.aggregate "PII", "PII attribute marking, masking, and erasure" do
            command("MarkPII") { attribute :field, String }
            command("Erase") { attribute :aggregate_id, String }
          end

          b.aggregate "Tenancy", "Multi-tenant data isolation" do
            command("SetTenant") { attribute :tenant_id, String }
          end

          b.aggregate "RateLimit", "Per-command rate limiting" do
            command("Check") { attribute :command_name, String; attribute :actor, String }
          end

          b.aggregate "RetryPolicy", "Automatic command retry with backoff" do
            command("RetryCommand") { attribute :command_name, String; attribute :max_retries, Integer }
          end

          b.aggregate "Idempotency", "Idempotency key tracking for commands" do
            command("Check") { attribute :idempotency_key, String }
          end

          b.aggregate "Slack", "Slack notification integration" do
            command("Notify") { attribute :channel, String; attribute :message, String }
          end

          b.aggregate "OutboxExtension", "Outbox pattern for reliable messaging" do
            command("Enqueue") { attribute :message, String }
            command("Poll") { attribute :batch_size, Integer }
          end

          b.aggregate "ReadmeWriter", "Generates per-extension Markdown README files from metadata" do
            command("Generate") { attribute :root, String }
          end

          Chapters.define_paragraphs(Extensions, b)
        }.build
      end
    end
  end
end
