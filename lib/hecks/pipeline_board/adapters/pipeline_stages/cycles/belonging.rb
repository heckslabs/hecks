# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module Cycles
        # Whether an event belongs to a Work item's stage, by the `belongs` word of the stage's
        # `CycleStage` row: `item`, `carried` or `after`, as the row's comment in the PipelineBoard
        # bluebook defines them. It only compares what the events already hold.
        module Belonging
          # The event that lands a branch on local main.
          LANDED = "Delivery::Landing.BranchLanded"

          module_function

          # @param rule [String] the row's `belongs` word (`item` when empty)
          # @param event [Hash] a journal row that may close the stage
          # @param held [Hash] `key:` the Work item, `start:` the event the stage started at,
          #   `landings:` from {.landings}, `landed_at:` when the item itself landed
          # @return [Boolean] whether the event closes the item's stage
          def belongs?(rule, event, held)
            case rule
            when "after" then true
            when "carried" then carried?(event, held)
            else item?(event, held)
            end
          end

          # @param ordered [Array<Hash>] journal rows, oldest first
          # @return [Hash{String => String}] each landed commit (seven characters) to when it was
          #   first landed
          def landings(ordered)
            landed = ordered.select { |event| "#{event[:aggregate]}.#{event[:name]}" == LANDED }
            landed.each_with_object({}) { |event, times| times[commit(event)] ||= event[:at].to_s if commit(event) }
          end

          # @param ordered [Array<Hash>] journal rows, oldest first
          # @param key [String] the Work item
          # @return [String, nil] when the item's branch first landed
          def landed_at(ordered, key)
            ordered.find { |event| "#{event[:aggregate]}.#{event[:name]}" == LANDED && key_of(event) == key }&.dig(:at)&.to_s
          end

          # The Work item an event names: its `work` link, its `branch` link, or its own id. A link
          # the log holds as a printed object (`#<...>`) names nothing and is passed over.
          #
          # @param event [Hash] a journal row
          # @return [String, nil] the key
          def key_of(event)
            links = event[:links] || {}
            [links["work"], links["branch"], event[:id]].map(&:to_s).find { |held| readable?(held) }
          end

          def item?(event, held)
            [key_of(event), event[:id].to_s].intersect?([held[:key], held[:start][:id].to_s])
          end

          def carried?(event, held)
            at = held[:landings][commit(event)]
            !at.nil? && !held[:landed_at].nil? && at >= held[:landed_at]
          end

          def commit(event)
            text = (event[:links] || {})["landed"].to_s
            readable?(text) ? text[0, 7] : nil
          end

          def readable?(text) = !text.empty? && !text.start_with?("#<")
        end
      end
    end
  end
end
