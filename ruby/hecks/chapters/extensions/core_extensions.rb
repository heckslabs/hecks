# = Hecks::Chapters::Extensions::CoreExtensions
#
# Self-describing sub-chapter for foundational cross-cutting
# extensions: logging, metrics, anti-corruption layer, tenancy,
# retry policy, web explorer UI, and README generation.
#
#   Hecks::Chapters::Extensions::CoreExtensions.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::CoreExtensions
      #
      # Bluebook sub-chapter for core extensions: logging, metrics, Bubble ACL, tenancy, retry, web explorer, and README writer.
      #
      module CoreExtensions
        def self.define(b)
          b.aggregate "Logging", "Structured logging for command dispatch" do
            command("Log") { attribute :message, String }
          end

          b.aggregate "Metrics", "Runtime metrics collection" do
            command("Record") { attribute :metric_name, String; attribute :value, Integer }
          end

          b.aggregate "Bubble", "Anti-Corruption Layer for legacy system translation" do
            command("TranslateInbound") { attribute :legacy_data, String }
            command("TranslateOutbound") { attribute :domain_data, String }
          end

          b.aggregate "Tenancy", "Multi-tenant data isolation" do
            command("SetTenant") { attribute :tenant_id, String }
          end

          b.aggregate "RetryPolicy", "Automatic command retry with backoff" do
            command("RetryCommand") { attribute :command_name, String; attribute :max_retries, Integer }
          end

          b.aggregate "WebExplorer", "HTML UI for browsing aggregates and events" do
            command("Browse") { attribute :domain_name, String }
            command("RenderView") { attribute :template, String }
          end

          b.aggregate "ReadmeWriter", "Generates per-extension Markdown README files from metadata" do
            command("Generate") { attribute :root, String }
          end
        end
      end
    end
  end
end
