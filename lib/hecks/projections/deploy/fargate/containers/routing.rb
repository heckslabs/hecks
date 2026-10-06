module Hecks
  module Projections
    module Deploy
      module Fargate
        module Containers
          # Reads the routes and the default container, and checks that the load balancer can reach
          # every container with a port. Included into `Reading`, which supplies the structs.
          module Routing
            private

            def default_name(settings, layout)
              name = settings.fetch(:default_container, layout.domain.name).to_s
              target = layout.all.find { |container| container.name == name }
              unless target
                raise ArgumentError,
                      "default_container #{name.inspect} is not a container; have #{layout.all.map(&:name).join(", ")}"
              end
              return name if target.port

              raise ArgumentError, "default_container #{name.inspect} has no port, so the listener cannot forward to it"
            end

            def routes(entries, layout)
              counts = Hash.new(0)
              Check.hashes!(entries, "routes", allowed: ROUTE_KEYS, required: [:container, :paths, :priority]).map do |entry|
                container = entry.fetch(:container).to_s
                counts[container] += 1
                route(entry, container, counts[container], layout)
              end
            end

            def route(entry, container, nth, layout)
              target = layout.balanced.find { |candidate| candidate.name == container }
              unless target
                raise ArgumentError, "routes name container #{container.inspect}, which is not a container with a port"
              end

              suffix = nth == 1 ? "" : nth.to_s
              Route.new(
                id: Check.logical_id!(entry.fetch(:id, "ListenerRule#{Yaml.camel(container)}#{suffix}"), "routes id"),
                container: container, priority: Check.integer!(entry.fetch(:priority), "routes priority", range: 1..50_000),
                paths: route_paths(entry.fetch(:paths), container)
              )
            end

            def route_paths(value, container)
              paths = Check.strings!(value, "routes[#{container}] paths", min: 1, max: 5)
              bad = paths.reject { |path| path.start_with?("/", "*") }
              raise ArgumentError, "routes[#{container}] paths must start with / or *, got #{bad.join(", ")}" unless bad.empty?

              paths
            end

            def check_unique!(layout)
              naming_table(layout).merge(placement_table(layout)).each do |what, values|
                repeated = values.tally.select { |_value, count| count > 1 }.keys
                raise ArgumentError, "#{what} must be unique; repeated: #{repeated.join(", ")}" unless repeated.empty?
              end
            end

            def naming_table(layout)
              {
                "container names"      => layout.all.map(&:name),
                "repository names"     => layout.all.map(&:repository_name),
                "image tag parameters" => layout.all.map(&:tag_parameter),
                "repository ids"       => layout.all.map(&:repository_id)
              }
            end

            def placement_table(layout)
              {
                "target group ids" => layout.balanced.map(&:target_group_id),
                "container ports"  => layout.balanced.map(&:port),
                "route ids"        => layout.routes.map(&:id),
                "route priorities" => layout.routes.map(&:priority)
              }
            end

            def check_reachable!(layout)
              routed = layout.routes.map(&:container) + [layout.default_container]
              stranded = layout.balanced.map(&:name) - routed
              return if stranded.empty?

              raise ArgumentError, "container(s) #{stranded.join(", ")} have a port but no route and are not the " \
                                   "default_container, so the load balancer never reaches them; " \
                                   "add a routes entry or drop the port"
            end
          end
        end
      end
    end
  end
end
