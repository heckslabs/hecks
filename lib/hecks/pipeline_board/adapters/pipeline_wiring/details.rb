# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # What a node declares, for the sidebar: an aggregate's description, commands with their goals
      # and events, lifecycle and queries; a port's operations; an adapter's port. Read from the IR
      # and never from a store.
      class Details
        # @param registry [Runtime::Registry] a booted registry
        def initialize(registry)
          @registry = registry
        end

        # @param node [Hash] a graph node
        # @return [Hash] the node with its `details`
        def enrich(node)
          node.merge(details: send(node[:kind], node))
        end

        private

        def aggregate(node)
          book = @registry.bluebooks[node[:domain]]
          held = book&.aggregates&.find { |candidate| candidate.hecks_name == node[:label] }
          return {} unless held

          { description: held.description.to_s, vision: vision(book, node), commands: commands(held),
            lifecycle: lifecycle(held), queries: queries(held) }
        end

        def vision(book, node)
          return "" unless node[:context] && book.respond_to?(:modules)

          row = book.modules.find { |held| held.name.to_s == node[:context] }
          row ? row.vision.to_s : ""
        end

        def commands(held)
          held.commands.map do |command|
            { name: name_of(command), goal: command.goal.to_s, emits: Array(command.emits).map(&:to_s) }
          end
        end

        def lifecycle(held)
          cycle = held.lifecycle
          return nil unless cycle

          { field: cycle.field.to_s, default: cycle.default.to_s, states: Array(cycle.states).map(&:to_s) }
        end

        def queries(held) = held.queries.map { |query| { name: name_of(query), description: query.description.to_s } }

        def port(node)
          declared = declared_ports.find { |held| held.name.to_s == node[:label] }
          return {} unless declared

          { operations: declared.operations.map { |operation| operation_of(operation) },
            answers:    Array(declared.answered_queries).map(&:to_s) }
        end

        # Every operation port an aggregate of any booted bluebook declares.
        def declared_ports
          aggregates = @registry.bluebooks.each_value.flat_map(&:aggregates)
          aggregates.flat_map { |held| held.respond_to?(:ports) ? held.ports : [] }
        end

        def operation_of(operation)
          { name: name_of(operation), direction: operation.direction.to_s, answers: operation.answers.to_s,
            refuses: operation.refuses.to_s, emits: Array(operation.emits).map(&:to_s) }
        end

        def adapter(node)
          held = @registry.adapters[node[:label]]
          return {} unless held

          { port:   (held.respond_to?(:port_name) ? held.port_name : held.port).to_s,
            fields: (held.respond_to?(:fields) ? Array(held.fields) : []).map(&:to_s) }
        end

        def name_of(item) = (item.respond_to?(:hecks_name) ? item.hecks_name : item.name).to_s
      end
    end
  end
end
