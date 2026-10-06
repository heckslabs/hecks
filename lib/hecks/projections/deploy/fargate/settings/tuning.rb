module Hecks
  module Projections
    module Deploy
      module Fargate
        module Settings
          # The optional service and build settings written onto a plan. Extended onto `Settings`,
          # which supplies the defaults.
          module Tuning
            private

            def check_alerts!(alerts, cdn)
              return unless alerts && Monitoring.cloudfront_metrics?(alerts) && cdn.nil?

              raise ArgumentError, "alerts cloudfront_5xx needs cdn options to be set, " \
                                   "so its metric subscription is declared with the distribution"
            end

            def tuning(plan, settings, base)
              tune_service(plan, settings, base)
              tune_build(plan, settings)
            end

            def tune_service(plan, settings, base)
              plan.execute_command = Check.boolean!(settings.fetch(:execute_command, false), "execute_command")
              plan.health_check_grace_period = optional_integer(settings, :health_check_grace_period, 0..2_147_483_647)
              plan.deregistration_delay = optional_integer(settings, :deregistration_delay, 0..3600)
              plan.desired_count_parameter = optional_id(settings, :desired_count_parameter)
              plan.db_name_parameter = optional_id(settings, :db_name_parameter)
              return unless plan.db_name_parameter && !base[:shared]

              raise ArgumentError, "db_name_parameter applies only to database \"Shared\""
            end

            def tune_build(plan, settings)
              plan.execution_database_grant = Check.boolean!(settings.fetch(:execution_role_database_grant, true),
                                                             "execution_role_database_grant")
              check_execution_grant!(plan)
              plan.domain_env = Check.map!(settings.fetch(:domain_env, {}), "domain_env", nil_ok: true)
              plan.install_dir = install_dir(settings.fetch(:install_dir, DEFAULT_INSTALL_DIR))
              plan.build_context_dir = build_context_dir(settings.fetch(:build_context_dir, ""))
            end

            def check_execution_grant!(plan)
              return if plan.execution_database_grant || !plan.extras[:execution_policies].empty?

              raise ArgumentError, "execution_role_database_grant false leaves the execution role without a policy; " \
                                   "add one to execution_policies"
            end

            def optional_integer(settings, key, range)
              settings.key?(key) ? Check.integer!(settings[key], key.to_s, range: range) : nil
            end

            def optional_id(settings, key)
              settings.key?(key) ? Check.logical_id!(settings[key], key.to_s) : nil
            end

            def install_dir(value)
              text = value.to_s
              return text if text.match?(%r{\A/[A-Za-z0-9_./-]*[A-Za-z0-9_.-]\z})

              raise ArgumentError, "install_dir must be an absolute path without a trailing slash, got #{value.inspect}"
            end

            def build_context_dir(value)
              text = value.to_s
              return text if text.empty? || text.match?(%r{\A[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/\z})

              raise ArgumentError,
                    "build_context_dir must be a relative directory ending in /, such as \"build/\", got #{value.inspect}"
            end
          end
        end
      end
    end
  end
end
