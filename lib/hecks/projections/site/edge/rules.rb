# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Edge
        # The load balancer's listener rules a route table needs.
        #
        # A route names the rule that carries its path with `alb_rule`. A route of a server other
        # than the website needs one unless a broader route of the same server has it: `/cms/*`
        # carries `/cms/_static/*` too. The website's routes need none, since the website takes
        # whatever no rule claims; the default row `/*` names that rule, written with no path
        # condition. A rule is refused that carries more paths than a condition may hold, that
        # carries no route, or that a lower-numbered rule of another server would answer first.
        class Rules
          # An ALB rule holds five condition values in all; the secret header's takes one.
          VALUES = 5

          # @param edge [Edge] the edge being built; its rows are set
          # @param rows [Array<Table::Row>] the route table's rows
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(edge, rows, problems)
            @edge = edge
            @rows = rows
            @problems = problems
          end

          # @return [Array<Hash{Symbol => Object}>] each rule by ascending priority, with `:rule`,
          #   `:priority`, `:origin`, `:target_group` and the `:paths` it carries
          def call
            check_names
            check_carried
            check_cross_origin
            @edge.rules.sort_by(&:priority).map { |rule| render(rule) }
          end

          private

          def render(rule)
            paths = carried(rule).map { |row| Pattern.edge(row.path) }.uniq
            check_values(rule, paths)
            { rule: rule.rule, priority: rule.priority, origin: rule.origin,
              target_group: @edge.upstream(rule.origin)&.target_group, paths: paths }
          end

          def carried(rule) = @rows.select { |row| row.alb_rule == rule.rule }

          def check_values(rule, paths)
            if paths.empty?
              problem("EdgeRule #{rule.rule}", "carries no route; name it with alb_rule: on a route")
            elsif paths.include?("/*") && paths.size > 1
              problem("EdgeRule #{rule.rule}", "carries /*, which every other path it lists is part of")
            end
            limit = @edge.setting.secret_header ? VALUES - 1 : VALUES
            return if paths.size <= limit

            problem("EdgeRule #{rule.rule}", "carries #{paths.size} paths; a rule holds at most #{limit} " \
                                             "condition values, so split it into two rules")
          end

          def check_names
            names = @edge.rules.map(&:rule)
            @rows.select(&:alb_rule).each do |row|
              rule = @edge.rules.find { |candidate| candidate.rule == row.alb_rule }
              next problem(row.path, "names alb_rule #{row.alb_rule}; rules are #{names.join(', ')}") unless rule
              next if rule.origin == row.origin

              problem(row.path, "is served from #{row.origin} but its rule #{rule.rule} forwards to #{rule.origin}")
            end
          end

          # A route of a server behind the load balancer other than the website has a rule of its
          # own or sits under a broader route of the same server that has one.
          def check_carried
            @rows.each do |row|
              next if row.origin == "website" || row.origin == "assets" || rule_of(row)

              problem(row.path, "is served from #{row.origin} and no rule carries it; name one with alb_rule: " \
                                "or put it under a broader #{row.origin} route that has one")
            end
          end

          # The rule that carries a route: its own, else the nearest broader route's of its server.
          def rule_of(row)
            named = @edge.rules.find { |rule| rule.rule == row.alb_rule }
            return named if named

            covers = @rows.select do |other|
              other.alb_rule && other.origin == row.origin &&
                Pattern.strictly_covers?(Pattern.edge(other.path), Pattern.edge(row.path))
            end
            covering = covers.find do |one|
              covers.none? do |other|
                Pattern.strictly_covers?(Pattern.edge(one.path), Pattern.edge(other.path))
              end
            end
            covering && @edge.rules.find { |rule| rule.rule == covering.alb_rule }
          end

          # A rule of another server, with a lower priority, whose paths include one a route's own
          # rule would answer later, is a route answered by the wrong server.
          def check_cross_origin
            fallback = default_priority
            @rows.each do |row|
              next if row.origin == "assets"

              own = rule_of(row)&.priority || fallback
              @edge.rules.each do |rule|
                next if rule.origin == row.origin || rule.priority >= own
                next unless carried(rule).any? { |other| Pattern.covers?(Pattern.edge(other.path), Pattern.edge(row.path)) }

                problem(row.path, "is served from #{row.origin} but rule #{rule.rule} (priority #{rule.priority}) " \
                                  "sends it to #{rule.origin} first")
              end
            end
          end

          def default_priority
            default = @rows.find { |row| row.path == "/*" }
            @edge.rules.find { |rule| rule.rule == default&.alb_rule }&.priority || Float::INFINITY
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
