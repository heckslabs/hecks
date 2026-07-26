# PortBuilder — evaluates a `Hecks.port "persistence" do ... end` block.
#
# A family declares the HOW-VERB a bind hangs off an aggregate, the SIGNAL that
# says whether the domain gets a value back (:reply) or announces an event and
# waits for a verdict (:effect), and the config FIELD NAMES its adapters need.
#
# A family NEVER names its adapters — the adapter declares the family. That
# inversion is what makes a new backend purely additive.
#
#   Hecks.port "persistence" do
#     verb   "persisted_by"
#     signal :reply
#     field  :database
#   end
module Hecksagain
  module Bluebook
    module DSL
      class PortBuilder
        def initialize(name)
          @name   = name
          @signal = :reply
        end

        def verb(value)   = @verb = value.to_s
        def signal(value) = @signal = value.to_sym

        def build
          IR::Port.new(name: @name, verb: @verb, signal: @signal)
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
