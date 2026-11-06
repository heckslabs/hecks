# frozen_string_literal: true

module Hecks
  module Adapters
    class IterationWatch
      # The limits a started Work row may run to before it is bloated, from the Tickets world's
      # `iteration_watch "Work", attempts: n, wait_minutes: n, over_budget: x, default_budget_minutes: n`.
      # A limit the world leaves out is the default here; nothing else in the code names a number.
      class Setting
        # The world verb that carries the limits.
        VERB = "iteration_watch"

        # The limits when the world declares none of them.
        DEFAULTS = { attempts: 3, wait_minutes: 15, over_budget: 1.5, default_budget_minutes: 45 }.freeze

        # @!attribute [r] attempts
        #   @return [Integer] consecutive failures of one kind at one step that make a row bloated
        # @!attribute [r] wait_minutes
        #   @return [Numeric] total minutes spent waiting that make a row bloated
        # @!attribute [r] over_budget
        #   @return [Numeric] the multiple of its budget a row may run before it is bloated
        # @!attribute [r] default_budget_minutes
        #   @return [Integer] the budget of a row that has none
        Limits = Struct.new(:attempts, :wait_minutes, :over_budget, :default_budget_minutes)

        # @param registry [Runtime::Registry, nil] whose Tickets world carries the setting
        # @return [Limits] the declared limits, each defaulting on its own
        def self.read(registry)
          declared = declared(registry)
          values = DEFAULTS.to_h { |name, fallback| [name, number(declared[name], fallback)] }
          Limits.new(values[:attempts].to_i, values[:wait_minutes], values[:over_budget], values[:default_budget_minutes].to_i)
        end

        # @return [Hash] the world's `iteration_watch` setting, empty when it declares none
        def self.declared(registry) = registry&.world("Tickets")&.for_verb(VERB) || {}

        def self.number(value, fallback) = value.nil? ? fallback : Float(value).then { |f| f == f.to_i ? f.to_i : f }
      end
    end
  end
end
