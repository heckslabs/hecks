# frozen_string_literal: true

require_relative "findings"

module Hecks
  module Projections
    module Site
      class Edge
        # The part of the edge checks that reads the listener rules and the routes: each rule is
        # well formed and reaches a target group, and every route the edge serves has the origin and
        # the policy it needs.
        class RouteChecks
          include Findings

          PRIORITIES = (1..50_000)

          # @param edge [Edge] the edge being read, its rows set
          # @param rows [Array<Table::Row>] the route table's rows
          # @param vocabulary [Hash{Symbol => Array<String>}] the Site chapter's closed sets
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(edge, rows, vocabulary, problems)
            @edge = edge
            @rows = rows
            @vocabulary = vocabulary
            @problems = problems
          end

          # @return [void]
          def call
            check_rules
            check_routes
          end

          private

          def check_rules
            return check_no_alb unless @edge.alb?

            check_listener
            @edge.rules.each { |rule| check_rule(rule) }
            repeated(@edge.rules.map(&:rule), "EdgeRule", &:itself)
            repeated(@edge.rules.map(&:priority), "EdgeRule priority", &:to_s)
          end

          def check_listener
            problem("EdgeRule", "rows need an Edge row with listener:") if @edge.rules.any? && !@edge.setting&.listener
          end

          # With `alb: false` nothing routes by listener rule, so a rule row, or a route that names
          # one, describes a load balancer the project says it does not have. Every route that is
          # served by a server behind the edge still needs the origin that reaches it.
          def check_no_alb
            problem("EdgeRule", "rows describe a load balancer, and the Edge row says alb: false") if @edge.rules.any?
            @rows.select(&:alb_rule).each do |row|
              problem(row.path, "names alb_rule #{row.alb_rule}, and the Edge row says alb: false")
            end
            @rows.each { |row| check_reachable(row) }
          end

          def check_reachable(row)
            return if row.cdn || !%w[cms domain].include?(row.origin) || @edge.upstream(row.origin)

            problem(row.path, "is served from #{row.origin}, which no EdgeOrigin maps, and with alb: false " \
                              "nothing else reaches it")
          end

          def check_rule(rule)
            label = "EdgeRule #{rule.rule}"
            member_of(label, "origin", rule.origin, :origin)
            problem(label, "has origin assets; the load balancer does not front the assets origin") if rule.origin == "assets"
            problem(label, "is not a logical id") unless Checks::LOGICAL_ID.match?(rule.rule.to_s)
            check_priority(label, rule)
            check_target_group(label, rule)
          end

          def check_priority(label, rule)
            return if PRIORITIES.cover?(rule.priority.to_i)

            problem(label, "has priority #{rule.priority}; a priority is #{PRIORITIES.first} to #{PRIORITIES.last}")
          end

          def check_target_group(label, rule)
            return if rule.origin.nil? || @edge.upstream(rule.origin)&.target_group

            problem(label, "forwards to #{rule.origin}, whose EdgeOrigin names no target_group")
          end

          def check_routes
            @rows.select { |row| row.cdn || row.alb_rule }.each { |row| check_route(row) }
            default_rows = @rows.select { |row| row.path == "/*" && row.cdn }
            problem("the route table", "needs one row for /* : the default behaviour") if default_rows.empty?
          end

          def check_route(row)
            return if row.origin == "assets" && !row.cdn

            problem(row.path, "has origin #{row.origin}, which no EdgeOrigin maps") unless @edge.upstream(row.origin)
            check_policy_mapped(row)
          end

          def check_policy_mapped(row)
            return unless row.cdn && !@edge.policy(row.cache, row.origin)

            problem(row.path, "has cache class #{row.cache} on #{row.origin}, which no EdgePolicy maps")
          end
        end
      end
    end
  end
end
