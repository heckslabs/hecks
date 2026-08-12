require_relative "behaviour/policy"

module Hecksagain
  class Bluebook
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

      # WHICH HEAD DECLARED IT, or nil for one declared on the chapter.
      #
      # A policy written inside an aggregate is HOISTED onto the chapter by the
      # builder, and that is where the runtime reads it — so nothing was ever lost
      # at runtime. What was lost is the record of where it was written, which is
      # a fact about the source, and the language holds facts about the source.
      # Deliberately absent from `to_h`: the wire format is a pinned
      # contract, and it does not carry this.
      attr_accessor :aggregate

      def initialize(name:, on_event: nil, trigger_command: nil, target_domain: nil, aggregate: nil)
        @name            = name.to_s
        @on_event        = on_event
        @trigger_command = trigger_command
        @target_domain   = target_domain
        @aggregate       = aggregate&.to_s
      end


    end
  end
end
