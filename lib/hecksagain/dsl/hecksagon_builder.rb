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
      # The binds being collected right now, or nil when no hecksagon is being
      # read. An aggregate class consults this to decide whether an unknown
      # method is a how-verb or an honest mistake.
      class << self
        attr_accessor :collector
      end

      attr_reader :binds

      def initialize(domain)
        @domain = domain
        @binds  = []
      end

      def build = IR::Hecksagon.new(domain: @domain, binds: @binds)

      def self.build(domain, &block)
        builder  = new(domain)
        resolver = ->(name) { BindingProxy.namespace(name, builder.binds) }

        # The collector is live only while this block runs, and is always put
        # back — an aggregate class outside a hecksagon must raise NoMethodError
        # like any other object.
        previous       = collector
        self.collector = builder.binds
        begin
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
        ensure
          self.collector = previous
        end

        builder.build
      end
    end
  end
end
