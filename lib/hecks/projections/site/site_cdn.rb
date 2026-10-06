# frozen_string_literal: true

require_relative "../../projector"
require_relative "../deploy/fargate/yaml"
require_relative "edge"

module Hecks
  module Projections
    module Site
      # The edge of a site's route table as the two blocks of a CloudFormation template that depend
      # on it: the distribution's cache behaviours and the load balancer's listener rules.
      #
      # The blocks are returned by name, `"behaviors"` and `"listener_rules"`, as text from the
      # left margin; a project whose `Edge` row says `alb: false` has no load balancer and gets
      # `"behaviors"` alone. `Regions` puts each between the markers of the same name in the
      # project's template, at the markers' indentation. The text is a pure function of the table
      # and the edge rows.
      module SiteCdn
        extend Projector::Target

        projects_as :site_cdn, emits: :files

        module_function

        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table and the edge
        # @param options [Hash{Symbol => Object}] `:registry` (Runtime::Registry) the project booted
        #   into; or `:table` (Table) and `:edge` (Edge), already read
        # @return [Hash{String => String}] each region's name to its text; empty when the chapter
        #   declares no edge, and without `"listener_rules"` when the edge has no load balancer
        # @raise [Table::Invalid] when the table or the edge is refused
        def call(bluebook:, options: {})
          registry = options[:registry]
          table = options[:table] || Table.read(bluebook, registry: registry)
          edge = options[:edge] || Edge.read(bluebook, table: table, vocabulary: Table.vocabulary(registry))
          return {} unless edge

          return { "behaviors" => behaviors(edge) } unless edge.alb?

          { "behaviors" => behaviors(edge), "listener_rules" => listener_rules(edge) }
        end

        # @param edge [Edge] a checked edge
        # @return [String] the default behaviour and the ordered list, ending in a newline
        def behaviors(edge)
          fargate = Deploy::Fargate::Cdn
          lines = fargate.behavior_lines("DefaultCacheBehavior", edge.default_behaviour, "")
          unless edge.behaviours.empty?
            lines << "CacheBehaviors:"
            edge.behaviours.each { |entry| lines.concat(fargate.behavior_lines(nil, entry, "  ")) }
          end
          "#{lines.join("\n")}\n"
        end

        # @param edge [Edge] a checked edge
        # @return [String] one listener rule resource per rule, by priority, ending in a newline
        def listener_rules(edge)
          edge.listener_rules.map { |rule| listener_rule(edge.setting, rule) }.join("\n")
        end

        def listener_rule(setting, rule)
          conditions = listener_conditions(setting, rule.fetch(:paths))
          [
            "#{rule.fetch(:rule)}:", "  Type: AWS::ElasticLoadBalancingV2::ListenerRule", "  Properties:",
            "    ListenerArn: #{setting.listener}", "    Priority: #{rule.fetch(:priority)}",
            *("    Conditions:" unless conditions.empty?), *conditions,
            "    Actions:", "      - Type: forward", "        TargetGroupArn: #{rule.fetch(:target_group)}"
          ].join("\n") << "\n"
        end

        # The path and secret-header conditions of a listener rule; the website's rule has no path.
        def listener_conditions(setting, paths)
          conditions = []
          unless paths == ["/*"]
            conditions.push("      - Field: path-pattern", "        Values: #{Deploy::Fargate::Yaml.flow_list(paths)}")
          end
          if setting.secret_header
            conditions.push("      - Field: http-header", "        HttpHeaderConfig:",
                            "          HttpHeaderName: #{setting.secret_header}",
                            "          Values: #{Deploy::Fargate::Yaml.flow_list([setting.secret_value])}")
          end
          conditions
        end
      end
    end
  end
end
