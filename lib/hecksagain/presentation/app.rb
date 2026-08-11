require "json"
require "rack"
require_relative "page"
require_relative "field_shape"
require_relative "index_renderer"
require_relative "record_renderer"
require_relative "form_renderer"
require_relative "query_renderer"
require_relative "params"

module Hecksagain
  module Presentation
    # The content-negotiated router: `GET /Banking/Account/Overdrawn.html`
    # renders the query view built in this directory; the identical path
    # with no extension (or `.json`) dispatches the SAME ask through
    # `Runtime::Dispatcher#query` and answers with its raw result — one
    # route, two representations, exactly the "change the file format on
    # the route" mechanism this was built around (docs/presentation-bluebook.md).
    #
    # A plain Rack app (`#call(env)`) — no Sinatra, no Rails. `rack` itself
    # is a LAZY dependency the same way `pg`/`oauth2`/`aws-sdk-lambda` are
    # for their own adapters (see the Gemfile's own comment) : a project
    # that never boots this file never needs it installed.
    class App
      def self.for(registry:, presentation_name:)
        config = Presentation.config(presentation_name) ||
                 raise(ArgumentError, "no presentation #{presentation_name.inspect} configured — " \
                                       "call Hecksagain::Presentation.configure(#{presentation_name.inspect}) { expose \"...\" } first")
        new(registry: registry, exposed: config.exposes)
      end

      def initialize(registry:, exposed:, dispatcher: nil)
        @registry   = registry
        @exposed    = exposed
        @dispatcher = dispatcher || Runtime::Dispatcher.new(registry)
      end

      def call(env)
        request = Rack::Request.new(env)
        route(request)
      rescue RouteNotFound => e
        respond(404, "text/plain", e.message)
      end

      class RouteNotFound < StandardError; end

      private

      def route(request)
        segments = request.path_info.split("/").reject(&:empty?)
        return home(request) if segments.empty?

        domain = segments[0]
        refuse_unexposed(domain)
        chapter = @registry.bluebook(domain) || raise(RouteNotFound, "no domain #{domain.inspect} loaded")

        return aggregate_route(request, chapter, *split_format(segments[1])) if segments.size == 2

        return verb_or_record_route(request, chapter, segments[1], *split_format(segments[2])) if segments.size == 3

        respond(404, "text/plain", "no route for #{request.path_info}")
      end

      def refuse_unexposed(domain)
        return if @exposed.include?(domain)

        raise RouteNotFound, "#{domain.inspect} is not exposed by this presentation — declared chapters: #{@exposed.join(', ')}"
      end

      def split_format(segment)
        name, format = segment.to_s.split(".", 2)
        [name, format || "json"]
      end

      # ---- home -------------------------------------------------------

      def home(request)
        format = request.params["format"] || "html"
        chapters = @exposed.to_h { |name| [name, @registry.bluebook(name)] }.compact
        return json(200, chapters.transform_values { |c| { aggregates: c.aggregates.map(&:hecks_name) } }) if format != "html"

        html("Exposed domains", IndexRenderer.render(chapters))
      end

      # ---- /:domain/:aggregate.:format ---------------------------------

      def aggregate_route(request, chapter, aggregate_name, format)
        aggregate = find_aggregate(chapter, aggregate_name)
        return respond(405, "text/plain", "GET only") unless request.get?

        if format == "html"
          html("#{chapter.name}::#{aggregate.hecks_name}", RecordRenderer.index(registry: @registry, domain: chapter.name, aggregate: aggregate),
               breadcrumbs: [[chapter.name, "/"], [aggregate.hecks_name, nil]])
        else
          instances = @registry.repository(chapter.name, aggregate).all
          # id LAST — see Instance#to_h's own comment: an aggregate free
          # to declare its own attribute literally named `id` has that
          # attribute's own wrapped value sitting in `i.state[:id]`
          # already, which used to silently clobber the correct bare
          # identity when merged first.
          json(200, instances.map { |i| i.state.merge(id: i.id) })
        end
      end

      # ---- /:domain/:aggregate/:verb_or_id.:format ----------------------

      def verb_or_record_route(request, chapter, aggregate_name, verb_or_id, format)
        aggregate = find_aggregate(chapter, aggregate_name)
        domain = chapter.name

        if (command = aggregate.command(verb_or_id))
          return command_route(request, domain, aggregate, command, format)
        end

        if (query = aggregate.query(verb_or_id))
          return query_route(request, domain, aggregate, query, format)
        end

        record_route(request, domain, aggregate, verb_or_id, format)
      end

      def command_route(request, domain, aggregate, command, format)
        action = "/#{domain}/#{aggregate.hecks_name}/#{command.hecks_name}.html"
        return command_json(request, domain, aggregate, command) if format != "html"
        return command_form(domain, aggregate, command, action, prefill: request.GET) if request.get?
        return respond(405, "text/plain", "GET or POST only") unless request.post?

        submit_command(request, domain, aggregate, command, action)
      end

      def command_form(domain, aggregate, command, action, status: 200, values: nil, error: nil, prefill: {})
        html("#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}",
             FormRenderer.render(registry: @registry, domain: domain, aggregate: aggregate, command: command,
                                  action: action, values: values, error: error, prefill: prefill),
             breadcrumbs: [[domain, "/"], [aggregate.hecks_name, "/#{domain}/#{aggregate.hecks_name}.html"], [command.hecks_name, nil]],
             status: status)
      end

      def submit_command(request, domain, aggregate, command, action)
        raw = request.POST
        fields = FormRenderer.fields_for(aggregate, command)
        args = Params.extract(fields, raw)
        result = @dispatcher.dispatch("#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}", **args)
        redirect("/#{domain}/#{aggregate.hecks_name}/#{result.id}.html")
      rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError, JSON::ParserError => e
        status = e.is_a?(Runtime::NotFound) ? 404 : 422
        command_form(domain, aggregate, command, action, status: status, values: raw, error: e)
      end

      def command_json(request, domain, aggregate, command)
        return json(200, command.to_h) if request.get? && request.GET.reject { |k, _| k == "format" }.empty?
        return respond(405, "text/plain", "GET or POST only") unless request.post?

        raw = request.POST
        fields = FormRenderer.fields_for(aggregate, command)
        args = Params.extract(fields, raw)
        result = @dispatcher.dispatch("#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}", **args)
        # id LAST — same reasoning as the other JSON-serializing call
        # sites in this file (see aggregate_route's own comment).
        json(201, result.state.merge(id: result.id))
      rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError, JSON::ParserError => e
        status = e.is_a?(Runtime::NotFound) ? 404 : 422
        json(status, { error: e.class.name.split("::").last, message: e.message })
      end

      def query_route(request, domain, aggregate, query, format)
        return respond(405, "text/plain", "GET only") unless request.get?

        params = request.GET
        asked = params.reject { |k, _| k == "format" }
        return query_json(domain, aggregate, query, asked) if format != "html"

        query_html(domain, aggregate, query, asked)
      end

      def query_html(domain, aggregate, query, asked)
        action = "/#{domain}/#{aggregate.hecks_name}/#{query.hecks_name}.html"
        fields = query.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
        results, error = asked.empty? ? [nil, nil] : run_query(domain, aggregate, query, fields, asked)
        html("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}",
             QueryRenderer.render(registry: @registry, domain: domain, aggregate: aggregate, query: query,
                                   action: action, params: asked, results: results, error: error),
             breadcrumbs: [[domain, "/"], [aggregate.hecks_name, "/#{domain}/#{aggregate.hecks_name}.html"], [query.hecks_name, nil]],
             status: error ? 422 : 200)
      end

      def query_json(domain, aggregate, query, asked)
        return json(200, query.to_h) if asked.empty?

        fields = query.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
        results, error = run_query(domain, aggregate, query, fields, asked)
        return json(422, { error: error.class.name.split("::").last, message: error.message }) if error

        # id LAST — same reasoning as the other JSON-serializing call
        # sites in this file (see aggregate_route's own comment).
        json(200, results.map { |i| i.state.merge(id: i.id) })
      end

      # `Dispatcher#query` answers an array of plain hashes
      # (`{id:}.merge(state)`, flattened by `QueryInterpreter#call` on
      # every path it can take — native pushdown or the in-memory
      # fallback alike), not `Runtime::Instance`. Wrapped into `Record`
      # here, once, so every renderer downstream reads one shape whether
      # its records came from a query or straight off a repository.
      def run_query(domain, aggregate, query, fields, asked)
        args = Params.extract(fields, asked)
        rows = @dispatcher.query("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}", **args)
        [rows.map { |row| Record.new(row[:id], row.reject { |k, _| k == :id }) }, nil]
      rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError => e
        [nil, e]
      end

      def record_route(request, domain, aggregate, id, format)
        return respond(405, "text/plain", "GET only") unless request.get?

        instance = @registry.repository(domain, aggregate).find(id)
        return not_found(aggregate, id, format) unless instance
        # id LAST — same reasoning as the other JSON-serializing call
        # sites in this file (see aggregate_route's own comment).
        return json(200, instance.state.merge(id: instance.id)) if format != "html"

        html("#{domain}::#{aggregate.hecks_name} #{id}", RecordRenderer.show(registry: @registry, domain: domain, aggregate: aggregate, id: id),
             breadcrumbs: [[domain, "/"], [aggregate.hecks_name, "/#{domain}/#{aggregate.hecks_name}.html"], [id, nil]])
      end

      def not_found(aggregate, id, format)
        return json(404, { error: "NotFound", message: "no #{aggregate.hecks_name} #{id}" }) if format != "html"

        respond(404, "text/html; charset=utf-8",
                Page.render(title: "not found", body: "<h1>Not found</h1><p>No #{Escape.html(aggregate.hecks_name)} #{Escape.html(id)}.</p>"))
      end

      def find_aggregate(chapter, name)
        chapter.aggregate(name) || raise(RouteNotFound, "#{chapter.name} has no aggregate #{name.inspect}")
      end

      # ---- rendering ----------------------------------------------------

      def html(title, body, breadcrumbs: [], status: 200)
        respond(status, "text/html; charset=utf-8", Page.render(title: title, body: body, breadcrumbs: breadcrumbs))
      end

      def json(status, payload)
        respond(status, "application/json", JSON.pretty_generate(payload))
      end

      def redirect(location)
        [302, { "location" => location }, []]
      end

      def respond(status, content_type, body)
        [status, { "content-type" => content_type }, [body]]
      end
    end
  end
end
