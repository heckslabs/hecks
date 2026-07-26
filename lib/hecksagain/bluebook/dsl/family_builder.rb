# FamilyBuilder — evaluates a `Hecks.family "persistence" do ... end` block.
#
# A family declares the HOW-VERB a bind hangs off an aggregate, the SIGNAL that
# says whether the domain gets a value back (:reply) or announces an event and
# waits for a verdict (:effect), and the config FIELD NAMES its adapters need.
#
# A family NEVER names its adapters — the adapter declares the family. That
# inversion is what makes a new backend purely additive.
#
#   Hecks.family "persistence" do
#     verb   "persisted_by"
#     signal :reply
#     field  :database
#   end
module Hecksagain
  module Bluebook
    module DSL
      class FamilyBuilder
        def initialize(name)
          @name   = name
          @fields = []
          @signal = :reply
        end

        def verb(value)   = @verb = value.to_s
        def signal(value) = @signal = value.to_sym
        def field(name)   = @fields << name.to_sym

        # A secret is a field whose VALUE is never stored in a bluebook — only
        # the name of the environment variable holding it.
        def secret(name) = @fields << name.to_sym

        def build
          IR::Family.new(name: @name, verb: @verb, signal: @signal, fields: @fields)
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
