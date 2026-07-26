# AdapterBuilder — evaluates a `Hecks.adapter "Sqlite" do ... end` block.
#
# The adapter DECLARES the family it implements — the inverted arrow. The bind
# `Pizzas::Pizza.persisted_by("Sqlite")` resolves if and only if Sqlite's
# declared family carries the `persisted_by` verb ; that is the typed attach
# checkpoint, and it fails at boot rather than at first fire.
#
# It also declares its own CONFIG FIELDS — names only ; the values live
# per-deployment in .world, and the world block is checked against this list.
# Fields belong here rather than on the family because adapters in one family
# genuinely differ: Heki needs a dir, Sqlite a database, Memory nothing. A
# field list on the family would force one shape onto all three, and Memory
# would have to carry configuration it has no use for.
#
# An adapter is named for its IDENTITY, never its transport.
#
#   Hecks.adapter "Sqlite" do
#     family "persistence"
#     field  :database
#   end
module Hecksagain
  module Bluebook
    module DSL
      class AdapterBuilder
        def initialize(name)
          @name    = name
          @fields  = []
          @secrets = []
        end

        def port(value) = @port = value.to_s

        # A config value this adapter needs. The .world supplies it.
        def field(name) = @fields << name.to_sym

        # As above, but the VALUE never lives in a bluebook — only the name of
        # the environment variable holding it.
        def secret(name) = @secrets << name.to_sym

        def build
          IR::Adapter.new(name: @name, port: @port, fields: @fields, secrets: @secrets)
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
