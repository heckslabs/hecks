# Hecks::Chapters::Templating
#
# Self-describing chapter for the HecksTemplating component. Covers
# naming convention helpers and browser-style HTTP smoke testing.
#
#   domain = Hecks::Chapters::Templating.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    # Hecks::Chapters::Templating
    #
    # Bluebook chapter defining the HecksTemplating component: naming helpers and HTTP smoke testing.
    #
    module Templating
      def self.definition
        DSL::DomainBuilder.new("Templating").tap { |b|
          b.aggregate "NamingHelpers" do
            description "Mixin providing domain naming convention methods for modules, gems, slugs, and routes"
            command "DomainModuleName" do
              attribute :name, String
            end
            command "DomainGemName" do
              attribute :name, String
            end
            command "DomainAggregateSlug" do
              attribute :name, String
            end
            command "DomainCommandMethod" do
              attribute :command_name, String
              attribute :aggregate_name, String
            end
            command "DomainRoutePath" do
              attribute :domain_name, String
              attribute :aggregate_name, String
            end
          end

          b.aggregate "SmokeTest" do
            description "Browser-style HTTP smoke test that exercises every page like a real user"
            command "Run" do
              attribute :base_url, String
              attribute :domain_name, String
            end
          end

          b.aggregate "FormSubmission" do
            description "Mixin for navigating to forms, filling fields, and submitting via POST"
            command "SubmitForm" do
              attribute :form_path, String
              attribute :command_name, String
            end
          end

          b.aggregate "EventChecks" do
            description "Mixin for validating event log entries via the /_events endpoint"
            command "CheckEventsContain" do
              attribute :expected_events, String
            end
          end

          b.aggregate "BehaviorTests" do
            description "Composite mixin for domain behavior smoke tests"
            command "TestQueries"
            command "TestScopes"
            command "TestSpecifications"
            command "TestPolicies"
            command "TestLifecycles"
            command "TestNegativeCases"
          end

          b.aggregate "EndpointTests" do
            description "Smoke tests for custom endpoint routes"
            command "TestEndpoints"
          end

          b.aggregate "LifecycleTests" do
            description "Smoke tests for lifecycle state transitions"
            command "TestLifecycles"
          end

          b.aggregate "QueryTests" do
            description "Smoke tests for query objects via /_queries endpoint"
            command "TestQueries"
          end

          b.aggregate "PolicyTests" do
            description "Smoke tests for policy event triggers"
            command "TestPolicies"
          end

          b.aggregate "DomainLookups" do
            description "Helper for resolving aggregates, commands, and events by name during smoke tests"
            command "LookupAggregate" do
              attribute :name, String
            end
          end
        }.build
      end
    end
  end
end
