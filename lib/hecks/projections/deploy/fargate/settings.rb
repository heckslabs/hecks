require_relative "check"
require_relative "yaml"
require_relative "containers"
require_relative "cdn"
require_relative "monitoring"
require_relative "extras"
require_relative "settings/ids"
require_relative "settings/tuning"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # Everything a `deployed_to("AwsFargate")` block can say beyond its
        # required settings, read and checked into one `Plan`.
        #
        # A world that sets none of these keys resolves entirely to the generator's own defaults.
        module Settings
          Plan = Struct.new(
            :ids, :names, :layout, :cdn, :alerts, :extras, :execute_command, :health_check_grace_period,
            :deregistration_delay, :desired_count_parameter, :domain_env, :install_dir, :build_context_dir,
            :db_name_parameter, :execution_database_grant,
            keyword_init: true
          )

          ID_ROLES = {
            service: nil, ecr_repository: "Repository", cluster: "Cluster", task_definition: "TaskDefinition",
            execution_role: "ExecutionRole", task_role: "TaskRole", log_group: "LogGroup", target_group: "TargetGroup",
            alb: "Alb", alb_security_group: "AlbSecurityGroup", listener: "Listener", distribution: "Distribution",
            session_secret: "SessionSecret", ingress_from_alb: "IngressFromAlb"
          }.freeze
          FIXED_IDS = {
            alerts_topic: "AlertsTopic", alerts_subscription: "AlertsTopicEmailSubscription", alb_5xx_alarm: "AlbTarget5xxAlarm",
            cloudfront_5xx_alarm: "CloudFront5xxAlarm", cloudfront_monitoring: "CloudFrontMonitoringSubscription",
            synthetic_alarm: "SyntheticCheckFailuresAlarm", warmer_role: "WarmerRole", warmer_function: "WarmerFunction",
            scheduler_role: "SchedulerInvokeRole", warmer_schedule: "WarmerSchedule"
          }.freeze
          NAME_ROLES = [:cluster, :log_group, :service, :alb, :family, :alb_security_group_description, :db_secret_policy].freeze
          DEFAULT_INSTALL_DIR = "/usr/local/bin".freeze

          extend Ids
          extend Tuning

          module_function

          # Reads and checks every optional setting into a frozen `Plan`, applying every default.
          def resolve(settings, base)
            ids = logical_ids(settings[:logical_ids], base)
            layout = Containers.normalize(settings, infra_name: base[:infra_name], port: base[:port], ids: ids)
            cdn = Cdn.normalize(settings[:cdn], default_origin_id: "#{ids[:alb]}Origin")
            alerts = read_alerts(settings, layout, cdn)
            plan = Plan.new(ids: ids, layout: layout, cdn: cdn, alerts: alerts, **plan_parts(settings, base))
            tuning(plan, settings, base)
            plan.freeze
          end

          # Lists every template parameter the plan declares beyond the generator's own.
          def parameters_yaml(plan, default_count:, shared_db_name:)
            [
              Containers.parameters_yaml(plan.layout), Cdn.parameters_yaml(plan.cdn),
              count_parameter_yaml(plan, default_count), db_name_parameter_yaml(plan, shared_db_name),
              Extras.parameters_yaml(plan.extras[:parameters])
            ].reject(&:empty?).join
          end

          def read_alerts(settings, layout, cdn)
            alerts = Monitoring.normalize(settings[:alerts], containers: layout.balanced.map(&:name))
            check_alerts!(alerts, cdn)
            alerts
          end
          private_class_method :read_alerts

          def plan_parts(settings, base)
            { names: names(settings[:names], base), extras: Extras.normalize(settings) }
          end
          private_class_method :plan_parts

          def count_parameter_yaml(plan, default_count)
            return "" unless plan.desired_count_parameter

            "#{plan.desired_count_parameter}:\n  Type: Number\n  Default: #{default_count}\n"
          end
          private_class_method :count_parameter_yaml

          def db_name_parameter_yaml(plan, shared_db_name)
            return "" unless plan.db_name_parameter

            "#{plan.db_name_parameter}:\n  Type: String\n  Default: #{Yaml.string(shared_db_name)}\n  " \
              "Description: The Postgres database name on the shared instance.\n"
          end
          private_class_method :db_name_parameter_yaml
        end
      end
    end
  end
end
