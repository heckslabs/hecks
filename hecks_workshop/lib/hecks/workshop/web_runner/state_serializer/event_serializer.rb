module Hecks
  class Workshop
    class WebRunner
      class StateSerializer
        # Hecks::Workshop::WebRunner::StateSerializer::EventSerializer
        #
        # Serializes the playground event log into JSON-ready hashes.
        # Each event includes its type, inferred command name, timestamp,
        # aggregate ID, and payload attributes.
        #
        #   EventSerializer.new(workshop).call
        #   # => [{ type: "Created", command: "Create", occurred_at: "...", ... }]
        #
        class EventSerializer
          PAST_TO_PRESENT = {
            /\ACanceled/ => "Cancel",
            /\ACreated/  => "Create",
            /\AUpdated/  => "Update",
            /\ADeleted/  => "Delete",
            /\AAdded/    => "Add",
            /\ARemoved/  => "Remove",
            /\APlaced/   => "Place"
          }.freeze

          def initialize(workshop)
            @workshop = workshop
          end

          def call
            return [] unless @workshop.play? && @workshop.playground

            @workshop.playground.events.map { |e| serialize_event(e) }
          end

          private

          def serialize_event(event)
            event_name = Hecks::Utils.const_short_name(event)
            {
              type:         event_name,
              command:      infer_command(event_name),
              occurred_at:  event.occurred_at&.to_s,
              aggregate_id: event.respond_to?(:aggregate_id) ? event.aggregate_id : nil,
              data:         extract_data(event)
            }
          end

          def infer_command(event_name)
            PAST_TO_PRESENT.each do |pattern, replacement|
              return event_name.sub(pattern, replacement) if event_name.match?(pattern)
            end
            event_name
          end

          def extract_data(event)
            attrs = {}
            event.class.instance_methods(false).each do |m|
              next if %i[occurred_at aggregate_id].include?(m)
              attrs[m] = event.send(m).inspect rescue nil
            end
            attrs
          end
        end
      end
    end
  end
end
