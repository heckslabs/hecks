require_relative "patterns"
require_relative "types"
require_relative "../hosting_settings"

module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # Reads the containers a box runs and what points at them: routes and the default.
          # Extended onto `Settings`, which supplies the checks.
          module ContainerReaders
            include Patterns
            include Types

            def read_containers(list, infra_name)
              raise ArgumentError, missing_containers unless list.is_a?(Array) && !list.empty?

              containers = list.map { |c| read_container(c, infra_name) }
              reject_repeat!(containers.map(&:name)) { |dup| "containers: two containers are named #{dup.inspect}" }
              reject_repeat!(containers.map(&:port)) do |clash|
                "containers: two containers listen on port #{clash}; they share the box's network"
              end
              containers
            end

            def read_container(spec, infra_name)
              raise ArgumentError, "containers: each container is a hash, got #{spec.inspect}" unless spec.is_a?(Hash)

              unnamed = spec.fetch(:name) { raise ArgumentError, "containers: a container has no name" }
              name = check(:container_name, unnamed, NAME)
              Container.new(name: name, **container_fields(spec, name, infra_name))
            end

            # @param name [String] a container name such as `web-app`
            # @return [String] the image-tag parameter a stack names it by, such as `WebAppImageTag`
            def default_tag_parameter(name)
              "#{name.split("-").map(&:capitalize).join}ImageTag"
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

            # A world that still declares `tunnel` is refused, so the tunnel it relied on does not
            # vanish from the box without a word (ADR 0156).
            #
            # @param settings [Hash{Symbol => Object}] the world's `AwsBox` settings
            # @raise [ArgumentError] when the world declares `tunnel`
            def refuse_tunnel!(settings)
              raise ArgumentError, TUNNEL_REMOVED if settings.key?(:tunnel)
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

            private

            def reject_repeat!(values)
              repeated = values.find { |value| values.count(value) > 1 }
              raise ArgumentError, yield(repeated) if repeated
            end

            def port_of(spec, name)
              spec.fetch(:port) { raise ArgumentError, "containers: #{name} has no port" }
            end

            def container_fields(spec, name, infra_name)
              {
                repository:    check(:repository, spec.fetch(:repository, "#{infra_name}-#{name}"), REPOSITORY),
                port:          integer(:port, port_of(spec, name), 1, 65_535),
                env:           string_map(:env, spec.fetch(:env, {}), ENV_KEY, ENV_VALUE),
                secrets:       string_map(:secrets, spec.fetch(:secrets, {}), ENV_KEY, SECRET_NAME),
                tag_parameter: check(:tag_parameter, spec.fetch(:tag_parameter, default_tag_parameter(name)),
                                     HostingSettings::PARAMETER),
                **build_fields(spec)
              }
            end

            # A container that names a Dockerfile is built from the checkout before push; one that
            # names none (both fields nil) pushes an image built elsewhere, as before.
            def build_fields(spec)
              dockerfile = spec[:dockerfile]
              return { dockerfile: nil, build_context: nil } if dockerfile.nil?

              {
                dockerfile:    relative_path(:dockerfile, dockerfile),
                build_context: relative_path(:context, spec.fetch(:context, "."))
              }
            end

            # A path inside the checkout: relative, not empty, and not climbing out of it with "..".
            def relative_path(key, value)
              str = value.to_s
              return str unless str.empty? || str.start_with?("/") || str.split("/").include?("..")

              raise ArgumentError, "#{key}: #{value.inspect} must be a path inside the checkout"
            end
          end
        end
      end
    end
  end
end
