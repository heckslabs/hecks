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
          NAME        = /\A[a-z][a-z0-9-]{0,40}\z/
          REPOSITORY  = %r{\A[a-z0-9][a-z0-9._/-]{1,100}\z}
          URL_PATH    = %r{\A/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*\z}
          SECRET_NAME = %r{\A[A-Za-z0-9/_+=.@-]{1,256}\*?\z}
          ENV_KEY     = /\A[A-Za-z_][A-Za-z0-9_]*\z/
          ENV_VALUE   = /\A[^\x00-\x1f\x7f]*\z/
          HEADER      = /\A[A-Za-z][A-Za-z0-9-]{0,63}\z/
          DB_NAME     = /\A[a-zA-Z][a-zA-Z0-9]{0,62}\z/
          ENGINE      = /\A\d{2}(\.\d{1,2})?\z/
          PREFIX      = /\A[a-z][a-z0-9-]{0,20}\z/
          IMAGE       = %r{\A[a-z0-9][a-z0-9._/:@-]{1,200}\z}
          TASKDEF     = /\A[a-zA-Z0-9_-]{1,255}\z/
          FROM_TASKDEF = %i[env secrets repository].freeze
          # Default images, each a version tag plus the digest of its multi-architecture index,
          # so a rebuilt box pulls the same bytes.
          TUNNEL_IMAGE = "cloudflare/cloudflared:2026.9.3" \
                         "@sha256:072c067d25ccbe61d46e18f0d0723255f2bb5304f7317caa95b27031520ff92c".freeze
          PROXY_IMAGE  = "public.ecr.aws/docker/library/caddy:2.8" \
                         "@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f".freeze
          TUNNEL_SHAPE = "tunnel: a hash needs `to` (the container it forwards to) and `token_secret` " \
                         "(the secret holding the tunnel token)".freeze
          ORIGIN_PAIR = "origin_header and origin_secret go together: the header a CDN sends, " \
                        "and the secret that holds its value".freeze

          # One container the box runs: its image repository, its port and its settings.
          #
          # @!attribute [r] name [String] the compose service name
          # @!attribute [r] repository [String] the ECR repository holding its images
          # @!attribute [r] port [Integer] the port it listens on, on the box's own network
          # @!attribute [r] env [Hash{String => String}] plain environment variables
          # @!attribute [r] secrets [Hash{String => String}] environment variable => secret name,
          #   resolved on the box at deploy time and never written into a template
          Container = Struct.new(:name, :repository, :port, :env, :secrets, keyword_init: true)

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

          # Everything the generator reads, checked.
          Plan = Struct.new(
            :infra_name, :stack_prefix, :instance_type, :volume_gb, :swap_gb, :database_class,
            :storage_gb, :backup_days, :snapshots_keep, :database_name, :engine_version,
            :containers, :routes, :default_container, :origin_header, :origin_secret,
            :secret_prefixes, :tunnel, :tunnel_service, :proxy_image, :task_definition, keyword_init: true
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
            listed = s.fetch(:containers) { raise ArgumentError, missing_containers }
            task_definition = read_task_definition(s[:task_definition], listed)
            containers = read_containers(listed, infra_name)
            header, secret = read_origin(s)
            tunnel, tunnel_service = read_tunnel(s.fetch(:tunnel, false), containers)

            Plan.new(
              infra_name: infra_name, stack_prefix: check(:stack_prefix, s.fetch(:stack_prefix, "hecks"), PREFIX),
              **declared_sizes(target), **read_sizes(s), database_name: read_database_name(s, infra_name),
              engine_version: check(:engine_version, s.fetch(:engine_version, "16").to_s, ENGINE),
              containers: containers, routes: read_routes(s.fetch(:routes, []), containers),
              default_container: read_default(s[:default_container], containers), origin_header: header,
              origin_secret: secret, secret_prefixes: read_prefixes(s, infra_name),
              tunnel: tunnel, tunnel_service: tunnel_service,
              proxy_image: check(:proxy_image, s.fetch(:proxy_image, PROXY_IMAGE), IMAGE),
              task_definition: task_definition
            )
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

              raise ArgumentError, "containers: #{spec[:name]} sets #{clash.join(', ')}, which the task definition " \
                                   "#{family} supplies; drop #{clash.size == 1 ? 'it' : 'them'} or drop task_definition"
            end
            family
          end

          def read_containers(list, infra_name)
            raise ArgumentError, missing_containers unless list.is_a?(Array) && !list.empty?

            containers = list.map { |c| read_container(c, infra_name) }
            names = containers.map(&:name)
            dup = names.find { |n| names.count(n) > 1 }
            raise ArgumentError, "containers: two containers are named #{dup.inspect}" if dup

            ports = containers.map(&:port)
            clash = ports.find { |p| ports.count(p) > 1 }
            raise ArgumentError, "containers: two containers listen on port #{clash}; they share the box's network" if clash

            containers
          end

          def read_container(spec, infra_name)
            raise ArgumentError, "containers: each container is a hash, got #{spec.inspect}" unless spec.is_a?(Hash)

            name = check(:container_name, spec.fetch(:name) { raise ArgumentError, "containers: a container has no name" }, NAME)
            Container.new(
              name: name, repository: check(:repository, spec.fetch(:repository, "#{infra_name}-#{name}"), REPOSITORY),
              port: integer(:port, spec.fetch(:port) { raise ArgumentError, "containers: #{name} has no port" }, 1, 65_535),
              env: string_map(:env, spec.fetch(:env, {}), ENV_KEY, ENV_VALUE),
              secrets: string_map(:secrets, spec.fetch(:secrets, {}), ENV_KEY, SECRET_NAME)
            )
          end

          def read_routes(list, containers)
            raise ArgumentError, "routes: expected a list" unless list.is_a?(Array)

            list.map { |spec| read_route(spec, containers) }
          end

          def read_route(spec, containers)
            container = spec.fetch(:container) { raise ArgumentError, "routes: a route has no container" }
            name = check(:route_container, container, NAME)
            known_container!(:routes, name, containers)
            paths = Array(spec.fetch(:paths) { raise ArgumentError, "routes: the route for #{name} has no paths" })
            raise ArgumentError, "routes: the route for #{name} has no paths" if paths.empty?

            Route.new(container: name, paths: paths.map { |p| check(:path, p, URL_PATH) })
          end

          def read_default(name, containers)
            return containers.first.name if name.nil? && containers.size == 1
            raise ArgumentError, "default_container: name the container that answers every other path" if name.nil?

            known_container!(:default_container, check(:default_container, name, NAME), containers)
          end

          def known_container!(key, name, containers)
            return name if containers.any? { |c| c.name == name }

            raise ArgumentError, "#{key}: #{name.inspect} is not a declared container"
          end

          def read_origin(settings)
            header = settings[:origin_header]
            secret = settings[:origin_secret]
            return [nil, nil] if header.nil? && secret.nil?
            raise ArgumentError, ORIGIN_PAIR if header.nil? || secret.nil?

            [check(:origin_header, header, HEADER), check(:origin_secret, secret, SECRET_NAME)]
          end

          # `tunnel true` only opens the outbound port; a hash also runs cloudflared as a service.
          #
          # @param value [Boolean, Hash{Symbol => Object}] the world's `tunnel` setting
          # @param containers [Array<Container>] the declared containers
          # @return [Array(Boolean, Tunnel)] whether the egress opens, and the service if one runs
          def read_tunnel(value, containers)
            return [boolean(:tunnel, value), nil] unless value.is_a?(Hash)

            to = value.fetch(:to) { raise ArgumentError, TUNNEL_SHAPE }
            target = known_container!(:tunnel, check(:tunnel_to, to, NAME), containers)
            token = check(:tunnel_token_secret, value.fetch(:token_secret) { raise ArgumentError, TUNNEL_SHAPE }, SECRET_NAME)
            image = check(:tunnel_image, value.fetch(:image, TUNNEL_IMAGE), IMAGE)
            port = containers.find { |c| c.name == target }.port
            [true, Tunnel.new(container: target, port: port, token_secret: token, image: image)]
          end

          def read_prefixes(settings, infra_name)
            list = Array(settings.fetch(:secret_prefixes, ["#{infra_name}/*"]))
            list.map { |p| check(:secret_prefixes, p, SECRET_NAME) }
          end

          def string_map(key, value, key_pattern, value_pattern)
            raise ArgumentError, "#{key}: expected a hash" unless value.is_a?(Hash)

            value.to_h { |k, v| [check(key, k.to_s, key_pattern), check(key, v.to_s, value_pattern)] }
          end

          def check(key, value, pattern)
            return value if value.is_a?(String) && value.match?(pattern)

            raise ArgumentError, "#{key}: #{value.inspect} does not match #{pattern.inspect}"
          end

          def integer(key, value, low, high)
            return value if value.is_a?(Integer) && value.between?(low, high)

            raise ArgumentError, "#{key}: #{value.inspect} must be an integer from #{low} to #{high}"
          end

          def boolean(key, value)
            return value if [true, false].include?(value)

            raise ArgumentError, "#{key}: #{value.inspect} must be true or false"
          end

          def missing_containers
            <<~MSG
              deployed_to("AwsBox") needs at least one container. Add one, e.g.:

                  deployed_to("AwsBox") do
                    region "us-east-1"
                    containers [{ name: "web", port: 8080 }]
                  end
            MSG
          end
        end
      end
    end
  end
end
