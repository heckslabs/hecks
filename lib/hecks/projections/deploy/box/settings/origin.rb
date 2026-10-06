require_relative "patterns"

module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # Reads the settings that guard and scope the box's secrets: the origin header and secret,
          # the variables that hold it, and the secret name prefixes. Extended onto `Settings`,
          # which supplies the checks.
          module OriginReaders
            include Patterns

            def read_origin(settings)
              header = settings[:origin_header]
              secret = settings[:origin_secret]
              return [nil, nil] if header.nil? && secret.nil?
              raise ArgumentError, ORIGIN_PAIR if header.nil? || secret.nil?

              [check(:origin_header, header, HEADER), check(:origin_secret, secret, SECRET_NAME)]
            end

            # The container environment variables that hold the origin secret in the task
            # definition. Only Caddy reads the named secret; the containers keep the task
            # definition's copy, so a copy that differs makes every request through the CDN
            # fail. Naming them lets deploy refuse a mismatch.
            #
            # @param settings [Hash{Symbol => Object}] the world's `AwsBox` settings
            # @param secret [String, nil] the declared origin secret
            # @param task_definition [String, nil] the declared task definition family
            # @return [Array<String>] the variable names, empty when none are declared
            # @raise [ArgumentError] when named without an origin secret and a task definition
            def read_origin_env(settings, secret, task_definition)
              names = Array(settings.fetch(:origin_env, []))
              return [] if names.empty?
              raise ArgumentError, ORIGIN_ENV_SHAPE if secret.nil? || task_definition.nil?

              names.map { |name| check(:origin_env, name, ENV_KEY) }.uniq
            end

            def read_prefixes(settings, infra_name)
              list = Array(settings.fetch(:secret_prefixes, ["#{infra_name}/*"]))
              list.map { |p| check(:secret_prefixes, p, SECRET_NAME) }
            end

            # Secrets the box may overwrite, such as one an admin page stores a key in. Production
            # only: a rehearsal box never changes a secret.
            def read_writable_secrets(settings)
              Array(settings.fetch(:writable_secrets, [])).map { |name| check(:writable_secrets, name, SECRET_NAME) }
            end
          end
        end
      end
    end
  end
end
