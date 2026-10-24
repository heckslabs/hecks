require_relative "containers"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The resolved, validated settings of one preview stack, built once by `build`.
        # Checked strictly: values feed CloudFormation names and a baked shell script.
        class Settings
          KEYS = %i[prefix alb_prefix owner_stack database_stack database_endpoint_output database_secret_output
                    db_prefix protected_databases protected_branches cpu memory log_retention_days session_cookie
                    first_admin signup_path landing_path db_init_image containers].freeze

          DEFAULT_DB_INIT_IMAGE = "public.ecr.aws/docker/library/postgres:16-alpine".freeze
          PREFIX_PATTERN = /\A[a-z0-9][a-z0-9-]{0,59}\z/
          ALB_PREFIX_PATTERN = /\A[a-z0-9][a-z0-9-]{0,9}[a-z0-9]\z/
          DB_PREFIX_PATTERN = /\A[a-z][a-z0-9_]{0,29}\z/
          STACK_PATTERN = /\A[A-Za-z][A-Za-z0-9_-]{0,127}\z/
          OUTPUT_PATTERN = /\A[A-Za-z0-9]+\z/
          BRANCH_PATTERN = %r{\A[A-Za-z0-9._/-]+\z}
          PATH_PATTERN = Containers::PATH_PATTERN
          COOKIE_PATTERN = /\A[A-Za-z0-9_.-]+\z/
          RETENTION_DAYS = [1, 3, 5, 7, 14, 30, 60, 90].freeze
          # An image reference the database-init task may pull.
          DB_INIT_IMAGE_PATTERN = %r{\A[A-Za-z0-9./:_@-]+\z}
          # A run of characters a stack prefix may not hold.
          NOT_PREFIX_RUN = /[^a-z0-9-]+/
          # Any character an ALB prefix may not hold.
          NOT_ALPHANUMERIC = /[^a-z0-9]/
          # A run of characters a database prefix may not hold.
          NOT_ALPHANUMERIC_RUN = /[^a-z0-9]+/
          # The characters before a name's first letter.
          LEADING_NON_LETTERS = Containers::LEADING_NON_LETTERS
          # The underscores a database prefix ends with.
          TRAILING_UNDERSCORES = /_+\z/

          attr_reader(*KEYS, :region, :stack_name, :infra_name, :main)

          # `raw` may be `true`, accepting every default.
          def self.build(raw, deploy_settings:, main:)
            raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_sym) : {}
            unknown = raw.keys - KEYS
            unless unknown.empty?
              raise ArgumentError, "unknown preview setting(s): #{unknown.join(", ")} (known: #{KEYS.join(", ")})"
            end

            new(raw, deploy_settings, main)
          end

          def initialize(raw, deploy_settings, main)
            @main = main
            @region = main.fetch(:region)
            @stack_name = main.fetch(:stack_name)
            @infra_name = main.fetch(:infra_name)
            assign_names(raw, main)
            assign_database(raw, main)
            assign_sizing(raw, main)
            assign_behaviour(raw)
            @containers = Containers.resolve(preview: raw, deploy_settings: deploy_settings, main: main,
                                             signup_path: (signup_path if first_admin))
          end

          def host = containers.find(&:host)

          def default_container = containers.find(&:default)

          def host_port = host.port

          private

          def assign_names(raw, main)
            prefix_default = "#{main.fetch(:stack_prefix)}-#{infra_name}-preview".downcase.gsub(NOT_PREFIX_RUN, "-")
            @prefix = pick(raw, :prefix, prefix_default, PREFIX_PATTERN)
            @alb_prefix = pick(raw, :alb_prefix, "#{infra_name.downcase.gsub(NOT_ALPHANUMERIC, "")[0, 8]}pv", ALB_PREFIX_PATTERN)
            assign_stacks(raw, main)
          end

          def assign_stacks(raw, main)
            @owner_stack = pick(raw, :owner_stack, main[:owner_stack] || stack_name, STACK_PATTERN)
            @database_stack = pick(raw, :database_stack, owner_stack, STACK_PATTERN)
            @database_endpoint_output = pick(raw, :database_endpoint_output, "DatabaseEndpoint", OUTPUT_PATTERN)
            @database_secret_output = pick(raw, :database_secret_output, "DatabaseSecretArn", OUTPUT_PATTERN)
          end

          def assign_database(raw, main)
            @db_prefix = pick(raw, :db_prefix, default_db_prefix, DB_PREFIX_PATTERN)
            extra = Array(raw[:protected_databases]).map(&:to_s)
            @protected_databases = ([main.fetch(:db_name).to_s.downcase, "postgres", "template0", "template1"] + extra).uniq
          end

          def default_db_prefix
            underscored = infra_name.downcase.gsub(NOT_ALPHANUMERIC_RUN, "_")
            underscored.sub(LEADING_NON_LETTERS, "")[0, 30].sub(TRAILING_UNDERSCORES, "")
          end

          def assign_sizing(raw, main)
            @cpu = Integer(raw.fetch(:cpu, main.fetch(:cpu)))
            @memory = Integer(raw.fetch(:memory, main.fetch(:memory)))
            @log_retention_days = Integer(raw.fetch(:log_retention_days, 7))
            return if RETENTION_DAYS.include?(log_retention_days)

            raise ArgumentError, "preview log_retention_days must be one of #{RETENTION_DAYS.join(", ")}"
          end

          def assign_behaviour(raw)
            @protected_branches = Array(raw.fetch(:protected_branches, %w[main master])).map(&:to_s)
            unless protected_branches.all? { |b| b.match?(BRANCH_PATTERN) }
              raise ArgumentError, "preview protected_branches must be plain branch names"
            end

            @session_cookie = pick(raw, :session_cookie, nil, COOKIE_PATTERN)
            @first_admin = raw.fetch(:first_admin, true) != false
            @signup_path = pick(raw, :signup_path, "/signups", PATH_PATTERN)
            @landing_path = pick(raw, :landing_path, "/", PATH_PATTERN)
            @db_init_image = pick(raw, :db_init_image, DEFAULT_DB_INIT_IMAGE, DB_INIT_IMAGE_PATTERN)
          end

          def pick(raw, key, default, pattern)
            value = raw.key?(key) ? raw[key] : default
            return value if value.nil?

            value = value.to_s
            return value if value.match?(pattern)

            raise ArgumentError, "preview #{key} #{value.inspect} must match #{pattern.inspect}"
          end
        end
      end
    end
  end
end
