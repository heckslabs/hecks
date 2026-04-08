# Hecks::Capabilities::ClientCommands::Router
#
# Decides which aggregates run client-side vs server-side based on
# the domain IR shape. No configuration needed — the Bluebook is
# the source of truth.
#
# Rules:
#   - No references to other aggregates → client candidate
#   - No CRUD-pattern commands (Create*, Delete*) → client candidate
#   - Has lifecycle/persistence needs → server
#
#   router = Router.new(domain)
#   router.client_side?("Layout")  # => true
#   router.server_side?("Pizza")   # => true
#   router.routing_table           # => { "Layout" => :client, ... }
#
module Hecks
  module Capabilities
    module ClientCommands
      # Hecks::Capabilities::ClientCommands::Router
      #
      # Infers client vs server routing from domain IR shape.
      #
      class Router
        UI_PREFIXES = %w[Toggle Select Open Close Show Hide Set Clear Pause Resume Enter Filter Track Switch Restore Save Connect Disconnect Subscribe Stop Inspect View Generate Define Rename Flag Link Add Prioritize Start Complete Accept Discover Load Get].freeze

        attr_reader :routing_table

        def initialize(domain)
          @routing_table = {}
          domain.aggregates.each do |agg|
            @routing_table[agg.name] = infer_side(agg)
          end
        end

        def client_side?(aggregate_name)
          @routing_table[aggregate_name.to_s] == :client
        end

        def server_side?(aggregate_name)
          !client_side?(aggregate_name)
        end

        def client_aggregates
          @routing_table.select { |_, v| v == :client }.keys
        end

        def server_aggregates
          @routing_table.select { |_, v| v == :server }.keys
        end

        private

        def infer_side(agg)
          return :server if has_references?(agg)
          return :client if all_ui_commands?(agg)
          :server
        end

        def has_references?(agg)
          return false unless agg.respond_to?(:references)
          agg.references.any?
        end

        def all_ui_commands?(agg)
          return false if agg.commands.empty?
          non_crud = agg.commands.reject { |cmd| cmd.name =~ /^(Create|Update|Delete|Read)#{agg.name}$/ }
          non_crud.all? { |cmd| UI_PREFIXES.any? { |p| cmd.name.start_with?(p) } }
        end
      end
    end
  end
end
