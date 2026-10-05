require "json"

# A CloudFront distribution configuration as `aws cloudfront get-distribution-config` answers it,
# built from a project's generated edge so a spec can change one thing about it.
module LiveDistribution
  module_function

  # @param edge [Hecks::Projections::Site::Edge] the project's edge
  # @return [Hash{String => String}] each policy intrinsic of the edge to a made-up id
  def refs_for(edge)
    names = ([edge.default_behaviour] + edge.behaviours).flat_map do |entry|
      entry.values_at(:cache_policy, :origin_request_policy, :response_headers_policy).compact.map(&:first)
    end
    names.uniq.select { |name| name.start_with?("!") }.each_with_index
         .to_h { |name, index| [name, format("00000000-0000-4000-8000-%012d", index)] }
  end

  # @param edge [Hecks::Projections::Site::Edge] the project's edge
  # @param refs [Hash{String => String}] what each intrinsic stands for live
  # @return [Hash] the distribution answer, with an ETag around the configuration
  def for(edge, refs: refs_for(edge))
    behaviours = edge.behaviours.map { |entry| behaviour(entry, refs).merge("PathPattern" => entry[:path]) }
    { "ETag"               => "E2QWRUHAPOMQZL",
      "DistributionConfig" => { "DefaultCacheBehavior" => behaviour(edge.default_behaviour, refs),
                                "CacheBehaviors"       => { "Quantity" => behaviours.size, "Items" => behaviours } } }
  end

  def behaviour(entry, refs)
    live = { "TargetOriginId" => entry[:origin], "ViewerProtocolPolicy" => entry[:viewer_protocol],
             "AllowedMethods" => { "Quantity" => entry[:methods].size, "Items" => entry[:methods],
                                   "CachedMethods" => { "Quantity" => 2, "Items" => %w[GET HEAD] } },
             "Compress" => entry[:compress] == true,
             "CachePolicyId" => id(entry[:cache_policy], refs) }
    request = id(entry[:origin_request_policy], refs)
    response = id(entry[:response_headers_policy], refs)
    live["OriginRequestPolicyId"] = request if request
    live["ResponseHeadersPolicyId"] = response if response
    live
  end

  def id(policy, refs) = policy && refs.fetch(policy.first, policy.first)
end
