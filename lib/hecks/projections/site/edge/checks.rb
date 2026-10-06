# frozen_string_literal: true

require_relative "findings"
require_relative "route_checks"

module Hecks
  module Projections
    module Site
      class Edge
        # What the edge rows must satisfy before anything is built from them: each reference is to a
        # thing that exists, no two rows claim one name or priority, and every route the edge serves
        # has the origin, the policy and, for a server behind the load balancer, the rule it needs.
        class Checks
          include Findings

          LOGICAL_ID = /\A[A-Za-z][A-Za-z0-9]*\z/
          INTRINSIC = /\A!(Ref|ImportValue|Sub|GetAtt)\s+\S/

          # The id a policy reference names, or nil when it names none.
          #
          # @param reference [String] a managed policy name, an id, or an intrinsic
          # @return [Array<String>, nil] `[id_or_intrinsic, comment_or_nil]`
          def self.resolve(reference)
            managed = Deploy::Fargate::Cdn::MANAGED_POLICIES[reference]
            return managed if managed
            return [reference, nil] if Deploy::Fargate::Cdn::UUID.match?(reference) || INTRINSIC.match?(reference)

            nil
          end

          # @param edge [Edge] the edge being read, its rows set
          # @param rows [Array<Table::Row>] the route table's rows
          # @param vocabulary [Hash{Symbol => Array<String>}] the Site chapter's closed sets
          # @param problems [Array<String>] collects each problem found, one line each
          # @param template_named [Boolean] whether the caller names the template itself
          def initialize(edge, rows, vocabulary, problems, template_named: false)
            @template_named = template_named
            @edge = edge
            @rows = rows
            @vocabulary = vocabulary
            @problems = problems
          end

          # @return [void]
          def call
            check_setting
            check_policies
            check_upstreams
            RouteChecks.new(@edge, @rows, @vocabulary, @problems).call
          end

          private

          def check_setting
            setting = @edge.setting
            return problem("Edge", "has no row; declare one member with template:") unless setting

            check_template(setting.template) if setting.template || !@template_named
            check_secret(setting)
          end

          def check_secret(setting)
            problem("Edge", "has secret_header but no secret_value") if setting.secret_header && !setting.secret_value
            problem("Edge", "has secret_value but no secret_header") if setting.secret_value && !setting.secret_header
          end

          def check_template(template)
            template = template.to_s
            problem("Edge", "has no template; declare template: or name the file to the tool") if template.empty?
            problem("Edge", "template #{template.inspect} must be a path inside the project") if
              template.start_with?("/") || template.split("/").include?("..")
          end

          def check_policies
            @edge.policies.each { |policy| check_policy(policy) }
            repeated(@edge.policies.map { |policy| [policy.cache_class, policy.origin] }, "EdgePolicy") do |key|
              policy_name(key[0], key[1])
            end
          end

          def check_policy(policy)
            label = "EdgePolicy #{policy_name(policy.cache_class, policy.origin)}"
            member_of(label, "cache_class", policy.cache_class, :cache)
            member_of(label, "origin", policy.origin, :origin) if policy.origin
            { cache: policy.cache, origin_request: policy.origin_request,
              response_headers: policy.response_headers }.compact.each do |field, reference|
              check_reference(label, field, reference)
            end
          end

          def check_reference(label, field, reference)
            return if (reference == "none" && field != :cache) || self.class.resolve(reference)

            managed = Deploy::Fargate::Cdn::MANAGED_POLICIES.keys.join(", ")
            problem(label, "has #{field} #{reference.inspect}; use a managed name (#{managed}), " \
                           "a policy id or an intrinsic like !Ref Name")
          end

          def policy_name(cache_class, origin) = "#{cache_class}#{" on #{origin}" if origin}"

          def check_upstreams
            @edge.upstreams.each do |upstream|
              member_of("EdgeOrigin #{upstream.origin}", "origin", upstream.origin, :origin)
              problem("EdgeOrigin #{upstream.origin}", "has id #{upstream.id.inspect}; an origin id is a logical id") unless
                LOGICAL_ID.match?(upstream.id.to_s)
            end
            repeated(@edge.upstreams.map(&:origin), "EdgeOrigin", &:itself)
          end
        end
      end
    end
  end
end
