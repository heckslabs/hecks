module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # The values a resolved box plan is made of. Included into `Settings`, so each reads as
          # `Settings::Container`, `Settings::Plan` and so on.
          module Types
            # One container the box runs: its image repository, its port and its settings.
            #
            # @!attribute [r] name [String] the compose service name
            # @!attribute [r] repository [String] the ECR repository holding its images
            # @!attribute [r] port [Integer] the port it listens on, on the box's own network
            # @!attribute [r] env [Hash{String => String}] plain environment variables
            # @!attribute [r] secrets [Hash{String => String}] environment variable => secret name,
            #   resolved on the box at deploy time and never written into a template
            # @!attribute [r] tag_parameter [String] the stack parameter that holds this container's
            #   image tag, which a hosting `deploy-service.sh` sets
            Container = Struct.new(:name, :repository, :port, :env, :secrets, :tag_parameter, keyword_init: true)

            # A set of URL paths one container serves.
            #
            # @!attribute [r] container [String] the container's name
            # @!attribute [r] paths [Array<String>] Caddy path patterns, such as "/cms/*"
            Route = Struct.new(:container, :paths, keyword_init: true)

            # A Cloudflare tunnel the box runs as a service, pointed at one container.
            #
            # @!attribute [r] container [String] the container the tunnel forwards to
            # @!attribute [r] port [Integer] that container's port
            # @!attribute [r] token_secret [String] the secret holding the tunnel token
            # @!attribute [r] image [String] the cloudflared image
            Tunnel = Struct.new(:container, :port, :token_secret, :image, keyword_init: true)

            # The data a project moves from its old database into the new RDS instance.
            #
            # @!attribute [r] schemas [Array<String>] the schemas to copy
            # @!attribute [r] database [String] the database holding them on the RDS instance
            # @!attribute [r] source_database [String] the database holding them on the old server
            Migration = Struct.new(:schemas, :database, :source_database, keyword_init: true)

            # An S3 bucket the box's role may read, and in production write.
            #
            # @!attribute [r] name [String] the bucket's name
            # @!attribute [r] write [Boolean] whether a production box may also write and delete
            Bucket = Struct.new(:name, :write, keyword_init: true)

            # Everything the generator reads, checked.
            Plan = Struct.new(
              :infra_name, :stack_prefix, :instance_type, :volume_gb, :swap_gb, :database_class,
              :storage_gb, :backup_days, :snapshots_keep, :database_name, :engine_version,
              :containers, :routes, :default_container, :origin_header, :origin_secret,
              :secret_prefixes, :writable_secrets, :origin_env, :tunnel, :tunnel_service, :proxy_image,
              :task_definition, :migration, :s3_buckets, :hosting, keyword_init: true
            ) do
              # @return [String] the CloudFormation stack that holds the database
              def rds_stack = "#{stack_prefix}-#{infra_name}-rds"

              # @return [String] the CloudFormation stack that holds the box
              def box_stack = "#{stack_prefix}-#{infra_name}-box"

              # @return [Container] the container that answers every path no route claims
              def default
                containers.find { |c| c.name == default_container }
              end
            end
          end
        end
      end
    end
  end
end
