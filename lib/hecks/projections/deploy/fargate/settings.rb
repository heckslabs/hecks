require_relative "check"
require_relative "yaml"
require_relative "containers"
require_relative "cdn"
require_relative "monitoring"
require_relative "extras"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # Everything a `deployed_to("AwsFargate")` block can say beyond its
        # required settings, read and checked into one `Plan`.
        #
        # A world that sets none of these keys resolves to a plan whose every
        # value is the generator's own default: the derived logical ids and
        # names, one container, no extra resources. That plan renders the same
        # template the generator has always produced.
        #
        # ## Settings owned here
        #
        # - `logical_ids`: a map of role to logical id that replaces the id derived from the
        #   stack name, so an existing stack's ids can be reproduced. The roles are `service`,
        #   `ecr_repository`, `cluster`, `task_definition`, `execution_role`, `task_role`,
        #   `log_group`, `target_group`, `alb`, `alb_security_group`, `listener`, `distribution`,
        #   `session_secret`, `ingress_from_alb`, `database_prefix` and `compute_prefix`, plus
        #   the alerting roles `Monitoring` lists. `database_prefix` and `compute_prefix` are the
        #   prefixes of the VPC and database ids and of the compute security-group ids.
        # - `names`: a map of role to the AWS name that replaces the derived one. The roles are
        #   `cluster`, `log_group`, `service`, `alb` and `family`; `db_secret_policy`, the name of
        #   the task role's database-secret policy (`DbSecretRead`); and
        #   `alb_security_group_description`, the load balancer's security group description
        #   (EC2 replaces the group when it changes).
        # - `execution_role_database_grant`: false leaves the database secret out of the
        #   execution role. The host reads that secret itself with the task role, so the
        #   execution role needs it only when a container's `ECS` `Secrets` names it;
        #   `execution_policies` must then hold a policy.
        # - `execute_command`: true lets `aws ecs execute-command` open a session in a container.
        # - `health_check_grace_period`: seconds `ECS` ignores failing load-balancer health
        #   checks after a task starts.
        # - `deregistration_delay`: seconds a target group drains a deregistered target.
        # - `desired_count_parameter`: makes the service's desired count a template parameter
        #   with this name, defaulting to `desired_count`.
        # - `domain_env`: extra environment variables for the domain container, a map of name to
        #   a value or intrinsic. A name the generator already sets replaces it; a `nil` value
        #   removes it.
        # - `install_dir`: where the Dockerfile installs the host binary and its `.wasm` and
        #   `.ir.json` files, and where `HECKS_WASM_PATH` and `HECKS_IR_PATH` point
        #   (`/usr/local/bin`).
        # - `build_context_dir`: a directory prefix for the Dockerfile's `COPY` sources.
        # - `db_name_parameter`: for `database "Shared"`, a template parameter that names the
        #   shared database, defaulting to the owner's name.
        module Settings
          module_function

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

          # Reads and checks every optional setting into a `Plan`.
          #
          # @param settings [Hash{Symbol => Object}] the world's `deployed_to("AwsFargate")`
          #   settings
          # @param base [Hash{Symbol => Object}] facts the generator has already resolved:
          #   `:infra_name`,
          #   `:logical_id`, `:db_id`, `:stack_name`, `:port`, `:desired_count` and `:shared`
          # @return [Plan] the checked settings with every default applied
          # @raise [ArgumentError] if any setting is malformed, or two settings contradict each
          #   other
          def resolve(settings, base)
            ids = logical_ids(settings[:logical_ids], base)
            layout = Containers.normalize(settings, infra_name: base[:infra_name], port: base[:port], ids: ids)
            cdn = Cdn.normalize(settings[:cdn], default_origin_id: "#{ids[:alb]}Origin")
            alerts = Monitoring.normalize(settings[:alerts], containers: layout.balanced.map(&:name))
            check_alerts!(alerts, cdn)
            plan = Plan.new(ids: ids, names: names(settings[:names], base), layout: layout, cdn: cdn, alerts: alerts,
                            extras: Extras.normalize(settings))
            tuning(plan, settings, base)
            plan.freeze
          end

          # Lists every template parameter the plan declares beyond the generator's own.
          #
          # @param plan [Plan] the resolved plan
          # @param default_count [Integer] the service's `desired_count`, the default of its
          #   parameter
          # @param shared_db_name [String, nil] the owning database's name, when `database "Shared"`
          # @return [String] flush-left parameter text separated by newlines, or empty
          def parameters_yaml(plan, default_count:, shared_db_name:)
            [
              Containers.parameters_yaml(plan.layout), Cdn.parameters_yaml(plan.cdn),
              count_parameter_yaml(plan, default_count), db_name_parameter_yaml(plan, shared_db_name),
              Extras.parameters_yaml(plan.extras[:parameters])
            ].reject(&:empty?).join
          end

          def logical_ids(overrides, base)
            given = if overrides
                      Check.hash!(overrides, "logical_ids",
                                  allowed: ID_ROLES.keys + FIXED_IDS.keys + [:database_prefix, :compute_prefix])
                    else
                      {}
                    end
            derived = ID_ROLES.to_h { |role, suffix| [role, suffix ? "#{base[:logical_id]}#{suffix}" : base[:logical_id]] }
            derived.merge!(FIXED_IDS)
            derived[:database_prefix] = base[:db_id]
            derived[:compute_prefix] = base[:logical_id]
            given.each { |role, id| derived[role] = Check.logical_id!(id, "logical_ids #{role}") }
            derived.freeze
          end
          private_class_method :logical_ids

          def names(overrides, base)
            given = overrides ? Check.hash!(overrides, "names", allowed: NAME_ROLES) : {}
            stack = base[:stack_name]
            derived = {
              cluster: stack, log_group: "/ecs/#{stack}", service: stack, alb: "#{stack}-alb",
              family: base[:infra_name], db_secret_policy: "DbSecretRead"
            }
            given.each { |role, name| derived[role] = named(role, name) }
            derived.freeze
          end
          private_class_method :names

          def named(role, value)
            return Check.resource_name!(value, "names #{role}") unless role == :alb_security_group_description

            text = value.to_s
            return text if text.match?(/\A[\x20-\x7e]{1,255}\z/)

            raise ArgumentError,
                  "names #{role} must be 1 to 255 printable ASCII characters (EC2 rejects anything else), got #{value.inspect}"
          end
          private_class_method :named

          def check_alerts!(alerts, cdn)
            return unless alerts
            if Monitoring.cloudfront_metrics?(alerts) && cdn.nil?
              raise ArgumentError, "alerts cloudfront_5xx needs cdn options to be set, " \
                                   "so its metric subscription is declared with the distribution"
            end
          end
          private_class_method :check_alerts!

          def tuning(plan, settings, base)
            plan.execute_command = Check.boolean!(settings.fetch(:execute_command, false), "execute_command")
            plan.health_check_grace_period = optional_integer(settings, :health_check_grace_period, 0..2_147_483_647)
            plan.deregistration_delay = optional_integer(settings, :deregistration_delay, 0..3600)
            plan.desired_count_parameter = optional_id(settings, :desired_count_parameter)
            plan.db_name_parameter = optional_id(settings, :db_name_parameter)
            if plan.db_name_parameter && !base[:shared]
              raise ArgumentError,
                    "db_name_parameter applies only to database \"Shared\""
            end

            plan.execution_database_grant = Check.boolean!(settings.fetch(:execution_role_database_grant, true),
                                                           "execution_role_database_grant")
            if !plan.execution_database_grant && plan.extras[:execution_policies].empty?
              raise ArgumentError, "execution_role_database_grant false leaves the execution role without a policy; " \
                                   "add one to execution_policies"
            end

            plan.domain_env = Check.map!(settings.fetch(:domain_env, {}), "domain_env", nil_ok: true)
            plan.install_dir = install_dir(settings.fetch(:install_dir, DEFAULT_INSTALL_DIR))
            plan.build_context_dir = build_context_dir(settings.fetch(:build_context_dir, ""))
          end
          private_class_method :tuning

          def optional_integer(settings, key, range)
            settings.key?(key) ? Check.integer!(settings[key], key.to_s, range: range) : nil
          end
          private_class_method :optional_integer

          def optional_id(settings, key)
            settings.key?(key) ? Check.logical_id!(settings[key], key.to_s) : nil
          end
          private_class_method :optional_id

          def install_dir(value)
            text = value.to_s
            unless text.match?(%r{\A/[A-Za-z0-9_./-]*[A-Za-z0-9_.-]\z})
              raise ArgumentError,
                    "install_dir must be an absolute path without a trailing slash, got #{value.inspect}"
            end

            text
          end
          private_class_method :install_dir

          def build_context_dir(value)
            text = value.to_s
            return text if text.empty? || text.match?(%r{\A[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/\z})

            raise ArgumentError,
                  "build_context_dir must be a relative directory ending in /, such as \"build/\", got #{value.inspect}"
          end
          private_class_method :build_context_dir

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
