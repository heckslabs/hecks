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
          @project_runtimes = {}
        end

        # Register a project runtime for workbench queries.
        def add_runtime(name, runtime)
          @project_runtimes[name] = runtime
        end

        def handle(msg)
          target = resolve_runtime(msg[:project])
          case msg[:action]&.to_s
          when "inspect"
            inspect_repo(target, msg[:aggregate])
          when "find"
            find_record(target, msg[:aggregate], msg[:id])
          when "events"
            event_history(target)
          when "aggregates"
            list_aggregates(target)
          when "projects"
            list_projects
          else
            { error: "Unknown workbench action: #{msg[:action]}" }
          end
        end

        private

        def resolve_runtime(project_name)
          return @project_runtimes[project_name] if project_name && @project_runtimes[project_name]
          @project_runtimes.values.first || @runtime
        end

        def list_projects
          {
            projects: @project_runtimes.map { |name, rt|
              { name: name, domain: rt.domain.name, aggregates: rt.domain.aggregates.size }
            }
          }
        end

        def inspect_repo(target, aggregate_name)
          repo = target[aggregate_name]
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

        def find_record(target, aggregate_name, id)
          repo = target[aggregate_name]
          return { error: "No repository for #{aggregate_name}" } unless repo
          record = repo.respond_to?(:find) ? repo.find(id) : nil
          return { error: "Not found: #{aggregate_name}##{id}" } unless record
          { aggregate: aggregate_name, record: record_to_hash(record) }
        rescue => e
          { error: "#{aggregate_name}##{id}: #{e.message}" }
        end

        def event_history(target)
          events = target.event_bus.events.last(50).reverse
          {
            count: target.event_bus.events.size,
            events: events.map { |e|
              {
                name: Hecks::Utils.const_short_name(e),
                timestamp: e.respond_to?(:timestamp) ? e.timestamp.to_s : nil,
                data: event_data(e)
              }
            }
          }
        end

        def list_aggregates(target)
          {
            domain: target.domain.name,
            aggregates: target.domain.aggregates.map { |a|
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
