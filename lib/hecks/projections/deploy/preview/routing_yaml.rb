require "json"
require_relative "../text_template"
require_relative "yaml_text"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The network edge of a preview stack: security groups, load balancer and service.
        # Paths are sliced into rules of at most five, the most a condition holds.
        module RoutingYaml
          CLOUDFRONT_PREFIX_LIST = "pl-3b927c52".freeze
          PATHS_PER_RULE = 5
          INGRESS_NOTE = <<~NOTE.chomp.freeze
            # One ingress rule per routed container on the shared owner security group, removed
            # with the stack. The group has a rules-per-group quota, so delete stale previews.
          NOTE

          extend YamlText

          module_function

          def networking(settings)
            ingress = settings.containers.select(&:routed?).map do |c|
              TextTemplate.render("preview/ingress.tmpl", logical: c.logical, port: c.port).chomp
            end
            [alb_security_group(settings), "#{INGRESS_NOTE}\n#{ingress.join("\n\n")}"]
          end

          def alb_security_group(settings)
            TextTemplate.render("preview/alb_security_group.tmpl", infra_name:  settings.infra_name,
                                                                   prefix_list: CLOUDFRONT_PREFIX_LIST).chomp
          end

          def load_balancing(settings)
            routed = settings.containers.select(&:routed?)
            [*routed.map { |c| target_group(c) }, alb(settings), listener(settings), *listener_rules(settings)]
          end

          def target_group(container)
            TextTemplate.render("preview/target_group.tmpl", logical: container.logical, port: container.port,
                                                             health_check_path: container.health_check_path).chomp
          end

          def alb(settings)
            TextTemplate.render("preview/alb.tmpl", alb_prefix: settings.alb_prefix).chomp
          end

          # The default action goes to the default container.
          def listener(settings)
            TextTemplate.render("preview/listener.tmpl", default_logical: settings.default_container.logical).chomp
          end

          def rule_specs(settings)
            settings.containers.reject(&:default).select(&:routed?).flat_map do |c|
              c.paths.each_slice(PATHS_PER_RULE).with_index.map do |slice, n|
                { container: c, paths: slice, id: rule_id(c, n) }
              end
            end
          end

          # Priorities count up in tens.
          def listener_rules(settings)
            rule_specs(settings).each_with_index.map { |spec, i| listener_rule(spec, (i + 1) * 10) }
          end

          def listener_rule(spec, priority)
            TextTemplate.render("preview/listener_rule.tmpl", id: spec[:id], priority: priority,
                                                              paths: spec[:paths].map { |p| JSON.generate(p) }.join(", "),
                                                              logical: spec[:container].logical).chomp
          end

          def rule_id(container, slice) = "ListenerRule#{container.logical}#{slice + 1}"

          def service(settings)
            rule_ids = rule_specs(settings).map { |spec| spec[:id] }
            balancers = indent(service_load_balancers(settings), 6)
            TextTemplate.render("preview/service.tmpl", depends_on:     (["Listener"] + rule_ids).join(", "),
                                                        prefix:         settings.prefix,
                                                        load_balancers: balancers).chomp
          end

          def service_load_balancers(settings)
            settings.containers.select(&:routed?).map do |c|
              "- ContainerName: #{c.name}\n  ContainerPort: #{c.port}\n  TargetGroupArn: !Ref #{c.logical}TargetGroup"
            end.join("\n")
          end
        end
      end
    end
  end
end
