require_relative "../record_renderer"

module Hecks
  module Forms
    class App
      # The routes that list an aggregate's records or show one of them, in HTML or JSON.
      module Records
        private

        def aggregate_route(request, chapter, aggregate_name, format)
          aggregate = find_aggregate(chapter, aggregate_name)
          return respond(405, "text/plain", "GET only") unless request.get?
          return aggregate_json(chapter, aggregate) unless format == "html"

          html("#{chapter.name}::#{aggregate.hecks_name}",
               RecordRenderer.index(registry: @registry, domain: chapter.name, aggregate: aggregate),
               breadcrumbs: [[chapter.name, "/"], [aggregate.hecks_name, nil]])
        end

        def aggregate_json(chapter, aggregate)
          instances = @registry.repository(chapter.name, aggregate).all
          # `id:` is merged last so an attribute named `id` in the state cannot clobber it.
          json(200, instances.map { |i| i.state.merge(id: i.id) })
        end

        def verb_or_record_route(request, chapter, aggregate_name, verb_or_id, format)
          aggregate = find_aggregate(chapter, aggregate_name)
          domain = chapter.name

          # A record id is free-form and can equal a verb name ("Close"), so a GET checks for
          # a record first. POST never views a record, so it matches the verb first.
          instance = request.get? && @registry.repository(domain, aggregate).find(verb_or_id)
          return show_record(domain, aggregate, instance, verb_or_id, format) if instance

          command = aggregate.command(verb_or_id)
          return command_route(request, domain, aggregate, command, format) if command

          query = aggregate.query(verb_or_id)
          return query_route(request, domain, aggregate, query, format) if query

          record_route(request, domain, aggregate, verb_or_id, format)
        end

        def record_route(request, domain, aggregate, id, format)
          return respond(405, "text/plain", "GET only") unless request.get?

          show_record(domain, aggregate, @registry.repository(domain, aggregate).find(id), id, format)
        end

        def show_record(domain, aggregate, instance, id, format)
          return not_found(aggregate, id, format) unless instance
          # `id:` last, as in `aggregate_route`.
          return json(200, instance.state.merge(id: instance.id)) if format != "html"

          html("#{domain}::#{aggregate.hecks_name} #{id}",
               RecordRenderer.show(registry: @registry, domain: domain, aggregate: aggregate, id: id),
               breadcrumbs: [[domain, "/"], [aggregate.hecks_name, "/#{domain}/#{aggregate.hecks_name}.html"],
                             [id, nil]])
        end

        def find_aggregate(chapter, name)
          chapter.aggregate(name) || raise(RouteNotFound, "#{chapter.name} has no aggregate #{name.inspect}")
        end
      end
    end
  end
end
