require "json"
require_relative "../field_shape"
require_relative "../params"
require_relative "../query_form_renderer"

module Hecks
  module Forms
    class App
      # The query routes of `Forms::App`: the form with its results, and the JSON adapter to the
      # same
      # query.
      module Queries
        private

        def query_route(request, domain, aggregate, query, format)
          return respond(405, "text/plain", "GET only") unless request.get?

          params = request.GET
          asked = params.except("format")
          return query_json(domain, aggregate, query, asked) if format != "html"

          query_html(domain, aggregate, query, asked)
        end

        def query_html(domain, aggregate, query, asked)
          action = "/#{domain}/#{aggregate.hecks_name}/#{query.hecks_name}.html"
          results, error = asked.empty? ? [nil, nil] : run_query(domain, aggregate, query, asked)
          html("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}",
               QueryFormRenderer.render(registry: @registry, domain: domain, aggregate: aggregate, query: query,
                                        action: action, params: asked, results: results, error: error),
               breadcrumbs: [[domain, "/"], [aggregate.hecks_name, "/#{domain}/#{aggregate.hecks_name}.html"],
                             [query.hecks_name, nil]],
               status:      error ? 422 : 200)
        end

        def query_json(domain, aggregate, query, asked)
          return json(200, query.to_h) if asked.empty?

          results, error = run_query(domain, aggregate, query, asked)
          return refusal_json(error, 422) if error

          # `id:` last, as in `aggregate_route`.
          json(200, results.map { |i| i.state.merge(id: i.id) })
        end

        # `Dispatcher#query` answers plain hashes, not `Runtime::Instance`; wrapping them
        # in `Record` gives the renderers one shape.
        def run_query(domain, aggregate, query, asked)
          fields = query.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
          begin
            args = Params.extract(fields, asked)
            rows = @dispatcher.query("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}", **args)
            [rows.map { |row| Record.new(row[:id], row.except(:id)) }, nil]
          # `Params.extract` parses a list-of-value-object line as JSON; rescuing
          # `JSON::ParserError` turns a malformed line into a 422 rather than a 500.
          rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError, JSON::ParserError => e
            [nil, e]
          end
        end
      end
    end
  end
end
