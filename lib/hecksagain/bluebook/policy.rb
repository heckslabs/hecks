# GENERATED — projected from the language's own Policy aggregate.
# DO NOT EDIT: the holding half is rendered, and Behaviour::Policy
# is where anything hand-written belongs.
require_relative "behaviour/policy"

module Hecksagain
  module Bluebook
    class Policy
      include Hecksagain::IR
      include Behaviour::Policy

      emits_ir(
        name:            :name,
        on_event:        :on_event,
        trigger_command: :trigger_command,
        target_domain:   :target_domain
      )

      attr_reader :name, :on_event, :trigger_command, :target_domain

      # AGGREGATE, DECLARED AND DELIBERATELY OFF THE WIRE
      # the wire format is a pinned contract, and it does not carry
      # where a policy was written before the builder hoisted it
      attr_accessor :aggregate

      def initialize(name:, on_event: nil, trigger_command: nil, target_domain: nil, aggregate: nil)
        @name = name.to_s
        @on_event = on_event
        @trigger_command = trigger_command
        @target_domain = target_domain
        @aggregate = aggregate&.to_s
      end
    end
  end
end
