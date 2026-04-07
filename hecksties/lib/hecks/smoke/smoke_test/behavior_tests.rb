# HecksTemplating::SmokeTest::BehaviorTests
#
# Aggregates all domain behavior smoke tests into a single mixin.
# Each concern lives in its own file under behavior_tests/.
#
#   class SmokeTest
#     include BehaviorTests  # pulls in query, scope, lifecycle, etc.
#   end
#
require_relative "behavior_tests/query_tests"
require_relative "behavior_tests/policy_tests"
require_relative "behavior_tests/lifecycle_tests"
require_relative "behavior_tests/negative_tests"
require_relative "behavior_tests/endpoint_tests"
require_relative "behavior_tests/domain_lookups"

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
