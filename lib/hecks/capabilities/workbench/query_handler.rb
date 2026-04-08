# Hecks::Capabilities::Workbench::QueryHandler
#
# Handles workbench queries: repository inspection, event history,
# aggregate listing. Operates against the live runtime.
#
#   handler = QueryHandler.new(runtime)
#   handler.handle({ action: "inspect", aggregate: "Pizza" })
#   # => { records: [...], count: 3 }
#
module Hecks
  module Capabilities
    module Workbench
      # Hecks::Capabilities::Workbench::QueryHandler
      #
      # Handles read-only workbench queries against the runtime.
      #
      class QueryHandler
        def initialize(runtime)
          @runtime = runtime
        end

        def handle(msg)
          case msg[:action]&.to_s
          when "inspect"
            inspect_repo(msg[:aggregate])
          when "find"
            find_record(msg[:aggregate], msg[:id])
          when "events"
            event_history
          when "aggregates"
            list_aggregates
          else
            { error: "Unknown workbench action: #{msg[:action]}" }
          end
        end

        private

        def inspect_repo(aggregate_name)
          repo = @runtime[aggregate_name]
          return { error: "No repository for #{aggregate_name}" } unless repo
          records = repo.respond_to?(:all) ? repo.all : []
          {
            aggregate: aggregate_name,
            count: records.size,
            records: records.map { |r| record_to_hash(r) }
          }
        rescue => e
          { error: "#{aggregate_name}: #{e.message}" }
        end

        def find_record(aggregate_name, id)
          repo = @runtime[aggregate_name]
          return { error: "No repository for #{aggregate_name}" } unless repo
          record = repo.respond_to?(:find) ? repo.find(id) : nil
          return { error: "Not found: #{aggregate_name}##{id}" } unless record
          { aggregate: aggregate_name, record: record_to_hash(record) }
        rescue => e
          { error: "#{aggregate_name}##{id}: #{e.message}" }
        end

        def event_history
          events = @runtime.event_bus.events.last(50).reverse
          {
            count: @runtime.event_bus.events.size,
            events: events.map { |e|
              {
                name: Hecks::Utils.const_short_name(e),
                timestamp: e.respond_to?(:timestamp) ? e.timestamp.to_s : nil,
                data: event_data(e)
              }
            }
          }
        end

        def list_aggregates
          {
            domain: @runtime.domain.name,
            aggregates: @runtime.domain.aggregates.map { |a|
              {
                name: a.name,
                commands: a.commands.map(&:name),
                attributes: a.attributes.map { |at|
                  type = at.type.respond_to?(:name) ? at.type.name.split("::").last : at.type.to_s
                  { name: at.name.to_s, type: type, default: at.default }
                }
              }
            }
          }
        end

        def record_to_hash(record)
          if record.respond_to?(:to_h)
            record.to_h
          else
            record.instance_variables.each_with_object({}) do |iv, h|
              h[iv.to_s.delete_prefix("@")] = record.instance_variable_get(iv)
            end
          end
        end

        def event_data(event)
          if event.respond_to?(:to_h)
            event.to_h
          else
            event.instance_variables.each_with_object({}) do |iv, h|
              val = event.instance_variable_get(iv)
              h[iv.to_s.delete_prefix("@")] = val
            end
          end
        end
      end
    end
  end
end
