# HecksagonBuilder — evaluates a `Hecks.hecksagon "Pizzas" do ... end` block.
#
# This file wires only the edges that LEAVE the domain. Intra-domain calls are
# handled by naming convention and never appear here, so a hecksagon stays
# small no matter how large the bluebook grows.
#
# The const_missing resolver is installed for exactly the duration of the block,
# which is what lets `Pizzas::Pizza` parse without Pizzas existing.
#
#   Hecks.hecksagon "Pizzas" do
#     Pizzas::Pizza.persisted_by("Sqlite")
#   end
module Hecksagain
  module DSL
    class HecksagonBuilder
      attr_reader :binds

      def initialize(domain)
        @domain = domain
        @binds  = []
      end

      def build = IR::Hecksagon.new(domain: @domain, binds: @binds)

      def self.build(domain, &block)
        builder  = new(domain)
        resolver = ->(name) { BindingProxy.namespace(name, builder.binds) }
        ConstShim.with(resolver) { builder.instance_eval(&block) } if block
        builder.build
      end
    end
  end
end
