# AdapterBuilder — evaluates a `Hecks.adapter "Sqlite" do ... end` block.
#
# The adapter DECLARES the family it implements — the inverted arrow. The bind
# `Pizzas::Pizza.persisted_by("Sqlite")` resolves if and only if Sqlite's
# declared family carries the `persisted_by` verb ; that is the typed attach
# checkpoint, and it fails at boot rather than at first fire.
#
# An adapter is named for its IDENTITY, never its transport.
#
#   Hecks.adapter "Sqlite" do
#     family "persistence"
#   end
module Hecksagain
  module Language
    module DSL
      class AdapterBuilder
        def initialize(name)
          @name = name
        end

        def family(value) = @family = value.to_s

        def build = IR::Adapter.new(name: @name, family: @family)

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
