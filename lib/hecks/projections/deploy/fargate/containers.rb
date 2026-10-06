require_relative "check"
require_relative "yaml"
require_relative "containers/reading"
require_relative "containers/rendering"
require_relative "containers/definition_lines"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The containers of one Fargate task and how the load balancer reaches them.
        # The domain container (`rust/host`) is always present; more are added via `containers`.
        module Containers
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

          extend Reading
          extend Rendering
          extend DefinitionLines

          module_function

          # Reads the container-related settings into a `Layout`.
          def normalize(settings, infra_name:, port:, ids:)
            domain = domain_container(settings[:domain_container], infra_name: infra_name, port: port, ids: ids)
            layout = Layout.new(domain: domain, extras: extra_containers(settings), routes: [], default_container: domain.name)
            layout.default_container = default_name(settings, layout)
            layout.routes = routes(settings.fetch(:routes, []), layout)
            check_unique!(layout)
            check_reachable!(layout)
            layout
          end
        end
      end
    end
  end
end
