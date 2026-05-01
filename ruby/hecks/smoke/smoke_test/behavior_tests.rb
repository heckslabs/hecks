# HecksTemplating::SmokeTest::BehaviorTests
#
# Aggregates all domain behavior smoke tests into a single mixin.
# Each concern lives in its own file under behavior_tests/.
#
#   class SmokeTest
#     include BehaviorTests  # pulls in query, scope, lifecycle, etc.
#   end
#
require "hecks/chapters/templating/behavior_tests_children"
Hecks::Chapters.load_aggregates(
  Hecks::Templating::BehaviorTestsChildren,
  base_dir: File.expand_path("behavior_tests", __dir__)
)

module HecksTemplating
  class SmokeTest
    # HecksTemplating::SmokeTest::BehaviorTests
    #
    # Aggregates all domain behavior smoke test mixins: queries, scopes, policies, lifecycles, and endpoints.
    #
    module BehaviorTests
      include QueryTests
      include PolicyTests
      include LifecycleTests
      include NegativeTests
      include EndpointTests
      include DomainLookups
    end
  end
end
