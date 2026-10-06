require "json"
require "uri"
require_relative "html"
require_relative "field_shape"
require_relative "field_renderer"
require_relative "reference_options"
require_relative "params"
require_relative "record_table"

module Hecks
  module Forms
    # The GET view of a query: canonical link, quick links, filter form and results.
    # See docs/command-form-and-query-form-bluebook.md.
    module QueryFormRenderer
      # Renders one query's whole GET view as the page body.
      #
      # @param view [Hash] `action:` (required), the form's URL path, and optionally `params:`
      #   (the values asked for), `results:` (the records found) and `error:` (a refusal to show)
      def self.render(registry:, domain:, aggregate:, query:, **view)
        action = view.fetch(:action)
        fields = query.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
        reference_options = ReferenceOptions.collect(registry, domain, fields)

        <<~HTML
          #{header(domain, aggregate, query)}
          #{canonical_link(action, fields)}
          #{quick_links(action, fields)}
          #{filter_form(action, fields, view.fetch(:params, {}), reference_options)}
          #{error_banner(view[:error])}
          #{results_section(aggregate, view[:results], domain)}
          #{inspect_panel(domain, aggregate, query, fields)}
        HTML
      end

      def self.header(domain, aggregate, query)
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}")}</h1>
          #{%(<p class="goal">#{Escape.html(query.description)}</p>) if query.description}
          #{badges(query)}
        HTML
      end

      def self.badges(query)
        parts = []
        parts << %(<span class="badge">limit #{Escape.html(query.limit.to_h[:value])}</span>) if query.limit
        parts.join
      end

      def self.canonical_link(action, fields)
        paths = Params.paths(fields)
        template = paths.empty? ? action : "#{action}?#{paths.map { |path| "#{path}={#{path}}" }.join("&")}"
        <<~HTML
          <p class="help">Every query is a plain GET — this exact URL is bookmarkable, linkable from a dashboard, curlable, whatever a feature needs:</p>
          <div class="link-row"><code id="canonical-link">#{Escape.html(template)}</code><button type="button" class="copy" data-copy="#canonical-link">copy</button></div>
        HTML
      end

      # Capped at the first closed-set field: a second would mean a cross product of links.
      def self.quick_links(action, fields)
        field = fields.find { |f| %i[select radio].include?(f.kind) }
        return "" unless field

        links = field.options.map do |value, label|
          href = "#{action}?#{field.path}=#{URI.encode_www_form_component(value)}"
          %(<a href="#{Escape.attr(href)}">#{Escape.html(field.label)}: #{Escape.html(label)}</a>)
        end
        %(<div class="example-links">#{links.join}</div>)
      end

      def self.filter_form(action, fields, params, reference_options)
        return "" if fields.empty?

        <<~HTML
          <form method="get" action="#{Escape.attr(action)}">
            #{fields.map { |f| FieldRenderer.render(f, values: params, reference_options: reference_options) }.join}
            <div class="actions"><button type="submit">Run query</button></div>
          </form>
        HTML
      end

      def self.error_banner(error)
        return "" unless error

        %(<div class="error-banner" role="alert"><p><strong>#{Escape.html(error.class.name.split("::").last)}</strong> — ) \
          "#{Escape.html(error.message)}</p></div>"
      end

      def self.results_section(aggregate, results, domain)
        return "" unless results

        "<h2>Results (#{results.size})</h2>#{RecordTable.render(aggregate, results, domain: domain)}"
      end

      def self.inspect_panel(domain, aggregate, query, fields)
        verb = "#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}"
        paths = Params.paths(fields)
        <<~HTML
          <details class="inspect">
            <summary>Inspect — #{Escape.html(verb)}</summary>
            <p>Parameters: #{paths.empty? ? "<em>none</em>" : paths.map { |p| "<code>#{Escape.html(p)}</code>" }.join(", ")}</p>
            <pre>#{Escape.html(JSON.pretty_generate(query.to_h))}</pre>
          </details>
        HTML
      end
    end
  end
end
