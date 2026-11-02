# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The wiring of a booted registry as a graph: an aggregate is a node, a policy is an edge from
      # the aggregate whose event it hears to the aggregate whose command it reaches, an `ask` goes
      # to a port node, and a port goes to the adapter bound to it. Only what is wired is drawn, so
      # an aggregate no policy or port touches is left out.
      class Graph
        # @param registry [Runtime::Registry] a booted registry
        def initialize(registry)
          @registry = registry
          @nodes = {}
          @edges = []
        end

        # @return [Hash] `nodes` and `edges`, each a Hash of plain strings
        def to_h
          policy_edges
          adapter_edges
          { nodes: @nodes.values, edges: @edges.uniq }
        end

        private

        def policy_edges
          @registry.bluebooks.each_value do |bluebook|
            bluebook.policies.each { |policy| edge_for(bluebook.name.to_s, policy) }
          end
        end

        def edge_for(domain, policy)
          from = aggregate_id(domain, policy.event_qualifier.to_s)
          target = policy.reaches.to_s
          return if from.empty? || target.empty?

          to = target.start_with?("ask :") ? nil : destination(domain, target)
          link(from, to, policy.name.to_s, to&.start_with?("port:") ? "ask" : "policy")
        end

        # The node a reach lands on: the port when the verb is a port operation, else the aggregate.
        def destination(domain, verb)
          parts = path_of(verb)
          return aggregate_id(domain, parts.first) if parts.size == 1
          return "port:#{parts.last}" if port?(parts.last)
          return aggregate_id(parts.first, parts[1]) if @registry.bluebooks.key?(parts.first)

          aggregate_id(domain, parts.first)
        end

        # The `Domain::Aggregate::Part` segments of a verb, without its command.
        def path_of(verb)
          owner = verb.split(".").first
          owner.to_s.split("::")
        end

        def port?(name) = port_names.include?(name.to_s)

        # Every port name: the plain ports the registry holds and the operation ports each
        # aggregate declares.
        def port_names
          @port_names ||= @registry.ports.keys.map(&:to_s) + @registry.bluebooks.each_value.flat_map { |book| owned_ports(book) }
        end

        def owned_ports(bluebook)
          bluebook.aggregates.flat_map { |aggregate| declared_ports(aggregate) }
        end

        def declared_ports(aggregate)
          aggregate.respond_to?(:ports) ? aggregate.ports.map { |port| port.name.to_s } : []
        end

        def aggregate_id(domain, aggregate) = aggregate.to_s.empty? ? "" : "#{domain}::#{aggregate.split("::").last}"

        def link(from, to, label, kind)
          return unless to

          node(from, from.split("::").first)
          node(to, from.split("::").first)
          @edges << { from: from, to: to, label: label, kind: kind }
        end

        # A port belongs to the domain of the aggregate that asks through it; an aggregate to its
        # own.
        def node(id, asking_domain)
          port = id.start_with?("port:")
          domain = port ? asking_domain : id.split("::").first
          label = id.split("::").last.sub("port:", "")
          @nodes[id] ||= { id: id, kind: port ? "port" : "aggregate", domain: domain, label: label }
        end

        def adapter_edges
          @registry.adapters.each_value do |adapter|
            port = adapter.respond_to?(:port_name) ? adapter.port_name : adapter.port
            next unless @nodes.key?("port:#{port}")

            bind(port, adapter.name.to_s)
          end
        end

        def bind(port, adapter)
          id = "adapter:#{adapter}"
          @nodes[id] = { id: id, kind: "adapter", domain: "", label: adapter }
          @edges << { from: "port:#{port}", to: id, label: "", kind: "adapter" }
        end
      end
    end
  end
end
