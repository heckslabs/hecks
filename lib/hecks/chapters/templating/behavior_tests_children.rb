# = Hecks::Chapters::Templating::BehaviorTestsChildren
#
# Paragraph listing the child modules of SmokeTest::BehaviorTests:
# query tests, policy tests, lifecycle tests, negative tests,
# endpoint tests, and domain lookups.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::Templating::BehaviorTestsChildren,
#     base_dir: File.expand_path("behavior_tests", __dir__)
#   )
#
module Hecks
  module Chapters
    module Templating
      # Hecks::Chapters::Templating::BehaviorTestsChildren
      #
      # Paragraph for BehaviorTests child modules: queries, policies, lifecycles, negatives, endpoints, lookups.
      #
      module BehaviorTestsChildren
        def self.define(b)
          b.aggregate "QueryTests", "Smoke tests for query objects via /_queries endpoint" do
            command("TestQueries")
          end

          b.aggregate "PolicyTests", "Smoke tests for policy event triggers" do
            command("TestPolicies")
          end

          b.aggregate "LifecycleTests", "Smoke tests for lifecycle state transitions" do
            command("TestLifecycles")
          end

          b.aggregate "NegativeTests", "Smoke tests for validation error paths" do
            command("TestNegativeCases")
          end

          b.aggregate "EndpointTests", "Smoke tests for custom endpoint routes" do
            command("TestEndpoints")
          end

          b.aggregate "DomainLookups", "Helper for resolving aggregates and commands by name during smoke tests" do
            command("LookupAggregate") { attribute :name, String }
          end
        end
      end
    end
  end
end
