require_relative "hosting_settings"
require_relative "settings/patterns"
require_relative "settings/types"
require_relative "settings/checks"
require_relative "settings/containers"
require_relative "settings/origin"

module Hecks
  module Projections
    module Deploy
      module Box
        # Resolves a world's `deployed_to("AwsBox")` settings into the checked plan the box
        # generator renders from.
        #
        # Every string that reaches a template or a script is matched against a conservative
        # pattern first, so a world file cannot splice shell, YAML or Caddy syntax into the output.
        # A setting the world leaves out resolves to the default the golden stack was built with.
        module Settings
          include Patterns
          include Types
          extend Checks
          extend ContainerReaders
          extend OriginReaders

          module_function

          # @param deploy_settings [Hash{Symbol => Object}] the world's `AwsBox` settings
          # @param target [Object] the validated `BoxTarget` (its instance type, volume, database
          #   class and storage, already checked by `Declare`)
          # @param infra_name [String] the stack name the world or the domain gives
          # @return [Plan] the resolved plan
          # @raise [ArgumentError] when a setting is missing, malformed or inconsistent
          def resolve(deploy_settings:, target:, infra_name:)
            s = deploy_settings
            check(:stack_name, infra_name, NAME)
            database_name = read_database_name(s, infra_name)
            listed = s.fetch(:containers) { raise ArgumentError, missing_containers }
            task_definition = read_task_definition(s[:task_definition], listed)
            containers = read_containers(listed, infra_name)
            edge = edge_fields(s, containers, task_definition)
            Plan.new(**plan_fields(s, target, infra_name, database_name, containers), **edge,
                     **extra_fields(s, task_definition, database_name))
          end

          # @return [Hash{Symbol => Object}] the task definition, the migration, S3 access and
          #   hosting
          def extra_fields(settings, task_definition, database_name)
            {
              task_definition: task_definition, migration: read_migration(settings[:migration], database_name),
              shared_database: read_shared_database(settings),
              s3_buckets: read_s3_access(settings.fetch(:s3_access, [])),
              hosting: HostingSettings.read(settings, task_definition)
            }
          end

          # @param settings [Hash{Symbol => Object}] the world's `AwsBox` settings
          # @param containers [Array<Container>] the declared containers
          # @param task_definition [String, nil] the declared task definition family
          # @return [Hash{Symbol => Object}] the origin guard and the tunnel
          def edge_fields(settings, containers, task_definition)
            header, secret = read_origin(settings)
            origin_env = read_origin_env(settings, secret, task_definition)
            tunnel, tunnel_service = read_tunnel(settings.fetch(:tunnel, false), containers)
            { origin_header: header, origin_secret: secret, origin_env: origin_env,
              tunnel: tunnel, tunnel_service: tunnel_service }
          end

          # @return [Hash{Symbol => Object}] the plan's names, sizes, routes and secret scopes
          def plan_fields(settings, target, infra_name, database_name, containers)
            {
              infra_name: infra_name, stack_prefix: check(:stack_prefix, settings.fetch(:stack_prefix, "hecks"), PREFIX),
              **declared_sizes(target), **read_sizes(settings), database_name: database_name,
              engine_version: check(:engine_version, settings.fetch(:engine_version, "16").to_s, ENGINE),
              containers: containers, routes: read_routes(settings.fetch(:routes, []), containers),
              default_container: read_default(settings[:default_container], containers),
              secret_prefixes: read_prefixes(settings, infra_name), writable_secrets: read_writable_secrets(settings),
              proxy_image: check(:proxy_image, settings.fetch(:proxy_image, PROXY_IMAGE), IMAGE)
            }
          end

          # @param target [Object] the declared `BoxTarget`
          # @return [Hash{Symbol => Object}] the sizes `Declare` has already validated
          def declared_sizes(target)
            %i[instance_type volume_gb database_class storage_gb].to_h { |key| [key, target.state[key].value] }
          end

          # @param settings [Hash{Symbol => Object}] the world's settings
          # @return [Hash{Symbol => Integer}] swap, backup retention and snapshot retention, bounded
          def read_sizes(settings)
            {
              swap_gb:        integer(:swap_gb, settings.fetch(:swap_gb, 2), 0, 64),
              backup_days:    integer(:backup_days, settings.fetch(:backup_days, 7), 1, 35),
              snapshots_keep: integer(:snapshots_keep, settings.fetch(:snapshots_keep, 7), 1, 1000)
            }
          end

          # @param value [Hash{Symbol => Object}, nil] the world's `migration` setting
          # @param database_name [String] the RDS database, which the schemas move into by default
          # @return [Migration, nil] the data to move, or nil when the world declares none
          # @raise [ArgumentError] when the setting is not a hash with a non-empty list of schemas
          def read_migration(value, database_name)
            return nil if value.nil?

            listed = migration_schemas(value)
            database = check(:migration_database, value.fetch(:database, database_name), DB_NAME)
            Migration.new(schemas: listed.map { |name| check(:migration_schemas, name, SCHEMA) }.uniq, database: database,
                          source_database: check(:migration_source_database, value.fetch(:source_database, database), DB_NAME))
          end

          def migration_schemas(value)
            raise ArgumentError, MIGRATION_SHAPE unless value.is_a?(Hash)

            listed = value.fetch(:schemas) { raise ArgumentError, MIGRATION_SHAPE }
            raise ArgumentError, MIGRATION_SHAPE unless listed.is_a?(Array) && !listed.empty?

            listed
          end

          # @param list [Array<Hash>] the world's `s3_access` setting
          # @return [Array<Bucket>] the buckets, each readable and optionally writable in production
          # @raise [ArgumentError] when the setting is not a list of bucket hashes
          def read_s3_access(list)
            raise ArgumentError, S3_SHAPE unless list.is_a?(Array)

            list.map do |spec|
              raise ArgumentError, S3_SHAPE unless spec.is_a?(Hash)

              name = check(:s3_bucket, spec.fetch(:bucket) { raise ArgumentError, S3_SHAPE }, S3_BUCKET)
              Bucket.new(name: name, write: boolean(:s3_write, spec.fetch(:write, false)))
            end.uniq(&:name)
          end

          # The stack of the RDS instance this site shares with others. The instance's size,
          # storage, engine and backups are the instance's, so a world that sets them is refused.
          #
          # @param settings [Hash{Symbol => Object}] the world's `AwsBox` settings
          # @return [String, nil] the shared stack's name, or nil for a database of its own
          # @raise [ArgumentError] when the name is malformed or the world also sizes the instance
          def read_shared_database(settings)
            return nil unless settings.key?(:shared_database)

            clash = SHARED_INSTANCE_SETTINGS & settings.keys
            unless clash.empty?
              raise ArgumentError, "shared_database: #{clash.join(", ")} size the instance, which belongs to the shared " \
                                   "stack #{settings[:shared_database]}; drop #{clash.size == 1 ? "it" : "them"}"
            end
            check(:shared_database, settings[:shared_database], NAME)
          end

          def read_database_name(settings, infra_name)
            check(:database_name, settings.fetch(:database_name, infra_name.gsub(/[^a-zA-Z0-9]/, "")), DB_NAME)
          end

          # With a task definition, the images, environment and secrets are read from it at deploy
          # time, so a container that also sets them is ambiguous and refused.
          #
          # @param family [String, nil] the ECS task definition family the world names
          # @param listed [Array<Hash>] the containers as the world wrote them
          # @return [String, nil] the checked family, or nil when the world does not use one
          # @raise [ArgumentError] when the family is malformed or a container sets what it supplies
          def read_task_definition(family, listed)
            return nil if family.nil?

            check(:task_definition, family, TASKDEF)
            Array(listed).each do |spec|
              clash = spec.is_a?(Hash) ? FROM_TASKDEF & spec.keys : []
              next if clash.empty?

              raise ArgumentError, "containers: #{spec[:name]} sets #{clash.join(", ")}, which the task definition " \
                                   "#{family} supplies; drop #{clash.size == 1 ? "it" : "them"} or drop task_definition"
            end
            family
          end
        end
      end
    end
  end
end
