# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # What each Tickets event does to the plan's held counts: the status a Work event moves an item
      # to, the epic and priority it names, and the title an Epic event gives. A pure table and
      # readers; {PlanSummary} owns the state they change.
      module PlanFold
        # The status each Work event leaves its item in.
        STATUS = { "WorkPlanned" => "planned", "WorkStarted" => "started", "WorkYielded" => "planned",
                   "WorkReleased" => "planned", "WorkReopened" => "planned", "WorkFinished" => "done",
                   "WorkDropped" => "dropped", "WorkLapsed" => "dropped" }.freeze
        # The Epic events that set an epic's title.
        TITLED = %w[EpicOpened EpicRetitled].freeze

        module_function

        # @param payload [Hash, nil] an event's payload
        # @param key [Symbol] the attribute asked for
        # @return [String, nil] its value, unwrapped from a value object; nil when absent
        def read(payload, key)
          found = symbolic(payload)[key]
          found = symbolic(found)[:value] if found.is_a?(Hash)
          found&.to_s
        end

        # @return [Hash] the hash with its keys as symbols; empty for anything else
        def symbolic(hash) = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}

        # @param event [Runtime::Event] a Work event
        # @return [String, nil] the slug of the Work item it is about
        def slug(event) = read(event.payload, :work) || event.id&.to_s

        # @param event [Runtime::Event] an Epic event
        # @return [String, nil] the key of the epic it is about
        def epic_key(event) = read(event.payload, :epic) || event.id&.to_s
      end
    end
  end
end
