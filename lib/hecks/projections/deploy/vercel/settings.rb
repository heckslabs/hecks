module Hecks
  module Projections
    module Deploy
      module Vercel
        # Resolves a world's `deployed_to("Vercel")` settings into the checked plan the generator
        # renders from.
        #
        # Every string that reaches `vercel.json` or the deploy script is matched against a
        # conservative pattern first, so a world file cannot splice shell or JSON into the output.
        # Secrets are named here, never held: `env` lists variable names, and the deploy script
        # reads each value from the caller's environment.
        module Settings
          NAME      = /\A[a-z0-9][a-z0-9-]{0,99}\z/
          SCOPE     = /\A[a-z0-9][a-z0-9_-]{0,99}\z/
          ENV_VAR   = /\A[A-Z][A-Z0-9_]{0,99}\z/
          CRON_PATH = %r{\A/[A-Za-z0-9/_.-]{0,200}\z}
          SCHEDULE  = %r{\A[0-9*/,-]+( [0-9A-Za-z*/,-]+){4}\z}

          # The variable the hecksagon's Postgres adapter reads; always set on deploy.
          DATABASE_ENV = "DATABASE_URL".freeze

          Plan = Data.define(:project, :scope, :region, :memory, :max_duration, :crons, :env)

          module_function

          # @param deploy_settings [Hash{Symbol => Object}] the world's `Vercel` settings
          # @param target [Object] the validated `VercelTarget` (region, memory and duration,
          #   already checked by `Declare`)
          # @param infra_name [String] the project name the world or the domain gives
          # @return [Plan] the resolved plan
          # @raise [ArgumentError] when a setting is malformed
          def resolve(deploy_settings:, target:, infra_name:)
            s = deploy_settings
            Plan.new(project: check(:project, infra_name, NAME), scope: optional(:scope, s[:scope], SCOPE),
                     region: target.state[:region].value, memory: target.state[:memory].value,
                     max_duration: target.state[:max_duration].value,
                     crons: read_crons(s.fetch(:crons, [])), env: read_env(s.fetch(:env, [])))
          end

          # @return [String] the value, when it matches
          # @raise [ArgumentError] when it does not
          def check(key, value, pattern)
            return value.to_s if value.to_s.match?(pattern)

            raise ArgumentError, "#{key} #{value.inspect} is not allowed here (it must match #{pattern.source})"
          end

          # @return [String, nil] the value, or nil when the world left it out
          def optional(key, value, pattern)
            value.nil? ? nil : check(key, value, pattern)
          end

          # @param list [Array<Hash>] `[{ path: "/cron/tick", schedule: "0 * * * *" }]`
          # @return [Array<Hash{Symbol => String}>] the checked crons
          def read_crons(list)
            raise ArgumentError, "crons must be a list of { path:, schedule: }" unless list.is_a?(Array)

            list.map do |cron|
              unless cron.is_a?(Hash) && cron.key?(:path) && cron.key?(:schedule)
                raise ArgumentError, "a cron needs a path and a schedule, got #{cron.inspect}"
              end

              { path: check(:cron_path, cron[:path], CRON_PATH), schedule: check(:cron_schedule, cron[:schedule], SCHEDULE) }
            end
          end

          # @param list [Array<String>] environment variable names the deploy sets on Vercel
          # @return [Array<String>] the names, `DATABASE_URL` first, each once
          def read_env(list)
            raise ArgumentError, "env must be a list of variable names" unless list.is_a?(Array)

            ([DATABASE_ENV] + list.map { |name| check(:env, name, ENV_VAR) }).uniq
          end
        end
      end
    end
  end
end
