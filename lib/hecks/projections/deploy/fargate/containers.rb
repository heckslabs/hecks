require_relative "check"
require_relative "yaml"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The containers of one Fargate task and how the load balancer reaches them.
        # The domain container (`rust/host`) is always present; more are added via `containers`.
        module Containers
          module_function

          Container = Struct.new(
            :name, :repository_id, :repository_name, :tag_parameter, :port, :health_path,
            :env, :secrets, :cpu, :memory, :essential, :target_group_id,
            keyword_init: true
          )
          Route = Struct.new(:id, :container, :paths, :priority, keyword_init: true)
          Layout = Struct.new(:domain, :extras, :routes, :default_container, keyword_init: true) do
            # Lists the domain container followed by every added container.
            def all = [domain, *extras]

            # Lists the containers that receive load-balancer traffic.
            def balanced = all.select(&:port)

            # Tells whether the stack has any container besides the domain's own.
            def multi? = !extras.empty?

            # Finds the container the listener forwards to by default.
            def default = all.find { |container| container.name == default_container }
          end

          DOMAIN_KEYS = [:name, :repository, :image_tag_parameter, :health_path, :essential].freeze
          CONTAINER_KEYS = [
            :name, :repository, :port, :health_path, :env, :secrets, :image_tag_parameter, :essential,
            :cpu, :memory, :repository_id, :target_group_id
          ].freeze
          ROUTE_KEYS = [:container, :paths, :priority, :id].freeze

          # Reads the container-related settings into a `Layout`.
          def normalize(settings, infra_name:, port:, ids:)
            domain = domain_container(settings[:domain_container], infra_name: infra_name, port: port, ids: ids)
            extras = Check.hashes!(settings.fetch(:containers, []), "containers", allowed:  CONTAINER_KEYS,
                                                                                  required: [:name, :repository])
                          .map do |entry|
              extra_container(entry)
            end
            layout = Layout.new(domain: domain, extras: extras, routes: [], default_container: domain.name)
            layout.default_container = default_name(settings, layout)
            layout.routes = routes(settings.fetch(:routes, []), layout)
            check_unique!(layout)
            check_reachable!(layout)
            layout
          end

          # Renders the ECR repository of every added container.
          def repositories_yaml(layout)
            layout.extras.map do |container|
              <<~REPOSITORY.rstrip
                #{container.repository_id}:
                  Type: AWS::ECR::Repository
                  Properties:
                    RepositoryName: #{container.repository_name}
                    ImageScanningConfiguration:
                      ScanOnPush: true
              REPOSITORY
            end.join("\n\n")
          end

          # Renders the image-tag parameter of every added container.
          def parameters_yaml(layout)
            layout.extras.map do |container|
              <<~PARAMETER
                #{container.tag_parameter}:
                  Type: String
                  Default: latest
                  Description: ECR image tag the #{container.name} container pulls.
              PARAMETER
            end.join
          end

          # Renders the added containers as `ContainerDefinitions` list entries.
          def definitions_yaml(layout, log_group_id)
            layout.extras.map { |container| definition_yaml(container, log_group_id) }.join("\n\n")
          end

          # Renders the target group of every added container.
          def target_groups_yaml(layout, vpc_ref, deregistration_delay)
            layout.extras.select(&:port).map do |container|
              [
                "#{container.target_group_id}:",
                "  Type: AWS::ElasticLoadBalancingV2::TargetGroup",
                "  Properties:",
                "    TargetType: ip",
                "    Port: #{container.port}",
                "    Protocol: HTTP",
                "    VpcId: #{vpc_ref}",
                "    HealthCheckPath: #{container.health_path}",
                "    HealthCheckPort: \"#{container.port}\"",
                target_group_attributes_yaml(deregistration_delay).gsub(/^/, "    ")
              ].join("\n").rstrip
            end.join("\n\n")
          end

          # Renders the `TargetGroupAttributes` property for a drain delay.
          def target_group_attributes_yaml(deregistration_delay)
            return "" unless deregistration_delay

            <<~ATTRIBUTES
              TargetGroupAttributes:
                - Key: deregistration_delay.timeout_seconds
                  Value: "#{deregistration_delay}"
            ATTRIBUTES
          end

          # Renders one listener rule per route.
          def listener_rules_yaml(layout, listener_id)
            layout.routes.map do |route|
              target = layout.all.find { |container| container.name == route.container }
              <<~RULE.rstrip
                #{route.id}:
                  Type: AWS::ElasticLoadBalancingV2::ListenerRule
                  Properties:
                    ListenerArn: !Ref #{listener_id}
                    Priority: #{route.priority}
                    Conditions:
                      - Field: path-pattern
                        Values: #{Yaml.flow_list(route.paths)}
                    Actions:
                      - Type: forward
                        TargetGroupArn: !Ref #{target.target_group_id}
              RULE
            end.join("\n\n")
          end

          # Renders the service's `LoadBalancers` entries for the added containers.
          def load_balancers_yaml(layout)
            layout.extras.select(&:port).map do |container|
              <<~ENTRY
                - ContainerName: #{container.name}
                  ContainerPort: #{container.port}
                  TargetGroupArn: !Ref #{container.target_group_id}
              ENTRY
            end.join
          end

          # Writes the `DependsOn` value that holds the service until the listener and its
          # rules exist.
          def depends_on(layout, listener_id)
            return listener_id if layout.routes.empty?

            Yaml.flow_list([listener_id, *layout.routes.map(&:id)])
          end

          # Finds the first and last container port the load balancer must reach.
          def port_range(layout)
            ports = layout.balanced.map(&:port)
            ports.min..ports.max
          end

          def domain_container(setting, infra_name:, port:, ids:)
            given = setting ? Check.hash!(setting, "domain_container", allowed: DOMAIN_KEYS) : {}
            name = Check.resource_name!(given.fetch(:name, infra_name), "domain_container name")
            repository = Check.resource_name!(given.fetch(:repository, infra_name), "domain_container repository")
            Container.new(
              name: name, repository_id: ids.fetch(:ecr_repository), repository_name: repository,
              tag_parameter: Check.logical_id!(given.fetch(:image_tag_parameter, "ImageTag"),
                                               "domain_container image_tag_parameter"),
              port: port, health_path: health_path(given, "domain_container"), env: {}, secrets: {},
              essential: given.key?(:essential) ? Check.boolean!(given[:essential], "domain_container essential") : nil,
              target_group_id: ids.fetch(:target_group)
            )
          end
          private_class_method :domain_container

          def extra_container(entry)
            name = Check.resource_name!(entry.fetch(:name), "containers name")
            where = "containers[#{name}]"
            base = Yaml.camel(name)
            Container.new(
              name: name, repository_name: Check.resource_name!(entry.fetch(:repository), "#{where} repository"),
              repository_id: Check.logical_id!(entry.fetch(:repository_id, "#{base}Repository"), "#{where} repository_id"),
              target_group_id: Check.logical_id!(entry.fetch(:target_group_id, "#{base}TargetGroup"), "#{where} target_group_id"),
              tag_parameter: Check.logical_id!(entry.fetch(:image_tag_parameter, "#{base}ImageTag"),
                                               "#{where} image_tag_parameter"),
              port: optional_port(entry, where), health_path: health_path(entry, where),
              env: Check.map!(entry.fetch(:env, {}), "#{where} env"),
              secrets: Check.map!(entry.fetch(:secrets, {}), "#{where} secrets"),
              cpu: optional_size(entry, :cpu, where), memory: optional_size(entry, :memory, where),
              essential: Check.boolean!(entry.fetch(:essential, true), "#{where} essential")
            )
          end
          private_class_method :extra_container

          def optional_port(entry, where)
            entry.key?(:port) ? Check.integer!(entry[:port], "#{where} port", range: 1..65_535) : nil
          end
          private_class_method :optional_port

          def optional_size(entry, key, where)
            entry.key?(key) ? Check.integer!(entry[key], "#{where} #{key}", range: 1..1_000_000) : nil
          end
          private_class_method :optional_size

          def health_path(entry, where)
            path = entry.fetch(:health_path, "/").to_s
            raise ArgumentError, "#{where} health_path must start with /, got #{path.inspect}" unless path.start_with?("/")

            path
          end
          private_class_method :health_path

          def default_name(settings, layout)
            name = settings.fetch(:default_container, layout.domain.name).to_s
            target = layout.all.find { |container| container.name == name }
            unless target
              raise ArgumentError,
                    "default_container #{name.inspect} is not a container; have #{layout.all.map(&:name).join(', ')}"
            end
            unless target.port
              raise ArgumentError,
                    "default_container #{name.inspect} has no port, so the listener cannot forward to it"
            end

            name
          end
          private_class_method :default_name

          def routes(entries, layout)
            counts = Hash.new(0)
            Check.hashes!(entries, "routes", allowed: ROUTE_KEYS, required: [:container, :paths, :priority]).map do |entry|
              container = entry.fetch(:container).to_s
              counts[container] += 1
              route(entry, container, counts[container], layout)
            end
          end
          private_class_method :routes

          def route(entry, container, nth, layout)
            target = layout.balanced.find { |candidate| candidate.name == container }
            raise ArgumentError, "routes name container #{container.inspect}, which is not a container with a port" unless target

            suffix = nth == 1 ? "" : nth.to_s
            Route.new(
              id: Check.logical_id!(entry.fetch(:id, "ListenerRule#{Yaml.camel(container)}#{suffix}"), "routes id"),
              container: container, priority: Check.integer!(entry.fetch(:priority), "routes priority", range: 1..50_000),
              paths: route_paths(entry.fetch(:paths), container)
            )
          end
          private_class_method :route

          def route_paths(value, container)
            paths = Check.strings!(value, "routes[#{container}] paths", min: 1, max: 5)
            bad = paths.reject { |path| path.start_with?("/", "*") }
            raise ArgumentError, "routes[#{container}] paths must start with / or *, got #{bad.join(', ')}" unless bad.empty?

            paths
          end
          private_class_method :route_paths

          def check_unique!(layout)
            {
              "container names"      => layout.all.map(&:name),
              "repository names"     => layout.all.map(&:repository_name),
              "image tag parameters" => layout.all.map(&:tag_parameter),
              "repository ids"       => layout.all.map(&:repository_id),
              "target group ids"     => layout.balanced.map(&:target_group_id),
              "container ports"      => layout.balanced.map(&:port),
              "route ids"            => layout.routes.map(&:id),
              "route priorities"     => layout.routes.map(&:priority)
            }.each do |what, values|
              repeated = values.tally.select { |_value, count| count > 1 }.keys
              raise ArgumentError, "#{what} must be unique; repeated: #{repeated.join(', ')}" unless repeated.empty?
            end
          end
          private_class_method :check_unique!

          def check_reachable!(layout)
            routed = layout.routes.map(&:container) + [layout.default_container]
            stranded = layout.balanced.map(&:name) - routed
            return if stranded.empty?

            raise ArgumentError, "container(s) #{stranded.join(', ')} have a port but no route and are not the " \
                                 "default_container, so the load balancer never reaches them; add a routes entry or drop the port"
          end
          private_class_method :check_reachable!

          # Renders one added container as a `ContainerDefinitions` entry.
          def definition_yaml(container, log_group_id)
            lines = [
              "- Name: #{container.name}",
              "  Image: !Sub \"${#{container.repository_id}.RepositoryUri}:${#{container.tag_parameter}}\"",
              "  Essential: #{container.essential}"
            ]
            lines << "  Cpu: #{container.cpu}" if container.cpu
            lines << "  Memory: #{container.memory}" if container.memory
            lines.concat(port_lines(container), log_lines(container, log_group_id), env_lines(container), secret_lines(container))
            lines.join("\n")
          end
          private_class_method :definition_yaml

          def port_lines(container)
            container.port ? ["  PortMappings:", "    - ContainerPort: #{container.port}"] : []
          end
          private_class_method :port_lines

          def log_lines(container, log_group_id)
            [
              "  LogConfiguration:", "    LogDriver: awslogs", "    Options:",
              "      awslogs-group: !Ref #{log_group_id}", "      awslogs-region: !Ref AWS::Region",
              "      awslogs-stream-prefix: #{container.name}"
            ]
          end
          private_class_method :log_lines

          def env_lines(container)
            return [] if container.env.empty?

            ["  Environment:"] + container.env.flat_map do |name, value|
              ["    - Name: #{name}", "      Value: #{Yaml.string(value)}"]
            end
          end
          private_class_method :env_lines

          def secret_lines(container)
            return [] if container.secrets.empty?

            ["  Secrets:"] + container.secrets.flat_map do |name, value|
              ["    - Name: #{name}", "      ValueFrom: #{Yaml.string(value)}"]
            end
          end
          private_class_method :secret_lines
        end
      end
    end
  end
end
