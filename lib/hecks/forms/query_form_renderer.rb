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
    # Query -> the page body for its GET view — the working half of what
    # `query_form.bluebook` names (see docs/command-form-and-query-form-
    # bluebook.md): a canonical, shareable link (queries are GETs — every
    # one of them is already a URL, so this says so up front rather than
    # hiding that behind a form); a row of ready-made links for any
    # closed-set parameter, since a caller filtering by an enum should not
    # have to fill in a form to get a link they could just click; a filter
    # form for everything else, which — being a GET form — produces
    # exactly the same kind of link on submit; and the results table once
    # a request actually supplies parameters.
    module QueryFormRenderer
      # Renders one query's whole GET view: header, canonical link, quick links, filter
      # form, any error, results, and the inspect panel.
      #
      # @param registry [Runtime::Registry] the booted registry, for resolving reference
      #   fields' target aggregates
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate the query belongs to
      # @param query [Bluebook::Query] the query being rendered
      # @param action [String] the form's `action` URL and the canonical link's base
      # @param params [Hash] the request's own query params, pre-filling the filter form
      # @param results [Array<Hash>, nil] the query's own answer rows; `nil` renders no
      #   results section
      # @param error [StandardError, nil] a raised error to show in the error banner;
      #   `nil` renders none
      # @return [String] the page body markup
      def self.render(registry:, domain:, aggregate:, query:, action:, params: {}, results: nil, error: nil)
        fields = query.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
        reference_options = ReferenceOptions.collect(registry, domain, fields)

        <<~HTML
          #{header(domain, aggregate, query)}
          #{canonical_link(action, fields)}
          #{quick_links(action, fields)}
          #{filter_form(action, fields, params, reference_options)}
          #{error_banner(error)}
          #{results_section(aggregate, results, domain)}
          #{inspect_panel(domain, aggregate, query, fields)}
        HTML
      end

      # Renders the query's title, description and badges.
      #
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate the query belongs to
      # @param query [Bluebook::Query] the query being rendered
      # @return [String] the header markup
      def self.header(domain, aggregate, query)
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}")}</h1>
          #{%(<p class="goal">#{Escape.html(query.description)}</p>) if query.description}
          #{badges(query)}
        HTML
      end

      # Renders the query's declared badges — today, just its `limit` when it declares one.
      #
      # @param query [Bluebook::Query] the query being rendered
      # @return [String] the badge markup; `""` when the query declares no `limit`
      def self.badges(query)
        parts = []
        parts << %(<span class="badge">limit #{Escape.html(query.limit.to_h[:value])}</span>) if query.limit
        parts.join
      end

      # Renders the query's plain-GET canonical link template, one `path={path}` per
      # parameter.
      #
      # @param action [String] the query's base URL
      # @param fields [Array<Forms::Field>] the resolved field tree naming the parameters
      # @return [String] the help text and the templated link markup
      def self.canonical_link(action, fields)
        paths = Params.paths(fields)
        template = paths.empty? ? action : "#{action}?#{paths.map { |path| "#{path}={#{path}}" }.join('&')}"
        <<~HTML
          <p class="help">Every query is a plain GET — this exact URL is bookmarkable, linkable from a dashboard, curlable, whatever a feature needs:</p>
          <div class="link-row"><code id="canonical-link">#{Escape.html(template)}</code><button type="button" class="copy" data-copy="#canonical-link">copy</button></div>
        HTML
      end

      # The one enum-shaped parameter (if there is one) rendered as literal,
      # clickable links — no form to fill in for "show me the suspended
      # ones". Capped at the first closed-set field on purpose: a second one
      # would mean a cross product of links, which reads as noise rather
      # than help. A query with more than one is still fully reachable
      # through the filter form below.
      #
      # @param action [String] the query's base URL
      # @param fields [Array<Forms::Field>] the resolved field tree to search for a
      #   `:select` or `:radio` field
      # @return [String] one clickable link per option of the first closed-set field
      #   found; `""` when no field is `:select` or `:radio`
      def self.quick_links(action, fields)
        field = fields.find { |f| %i[select radio].include?(f.kind) }
        return "" unless field

        links = field.options.map do |value, label|
          href = "#{action}?#{field.path}=#{URI.encode_www_form_component(value)}"
          %(<a href="#{Escape.attr(href)}">#{Escape.html(field.label)}: #{Escape.html(label)}</a>)
        end
        %(<div class="example-links">#{links.join}</div>)
      end

      # Renders the GET filter form covering every declared parameter.
      #
      # @param action [String] the form's `action` URL
      # @param fields [Array<Forms::Field>] the resolved field tree to render
      # @param params [Hash] the request's own query params, pre-filling each field
      # @param reference_options [Hash{String => Array<Array(String, String)>, nil}] each
      #   `:reference` field's own dropdown options, as `ReferenceOptions.collect` returns
      # @return [String] the form markup; `""` when the query declares no parameters
      def self.filter_form(action, fields, params, reference_options)
        return "" if fields.empty?

        <<~HTML
          <form method="get" action="#{Escape.attr(action)}">
            #{fields.map { |f| FieldRenderer.render(f, values: params, reference_options: reference_options) }.join}
            <div class="actions"><button type="submit">Run query</button></div>
          </form>
        HTML
      end

      # Renders a raised error as a dismissable-looking alert banner.
      #
      # @param error [StandardError, nil] the error to show
      # @return [String] the banner markup; `""` when `error` is `nil`
      def self.error_banner(error)
        return "" unless error

        %(<div class="error-banner" role="alert"><p><strong>#{Escape.html(error.class.name.split('::').last)}</strong> — ) \
          "#{Escape.html(error.message)}</p></div>"
      end

      # Renders the results heading and table, once a request actually supplied
      # parameters.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose fields shape the table
      # @param results [Array<Hash>, nil] the query's own answer rows
      # @param domain [String] the owning chapter's name, for building record links
      # @return [String] the results section markup; `""` when `results` is `nil`
      def self.results_section(aggregate, results, domain)
        return "" unless results

        "<h2>Results (#{results.size})</h2>#{RecordTable.render(aggregate, results, domain: domain)}"
      end

      # Renders a collapsed panel with the query's own parameter list and raw IR JSON.
      #
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate the query belongs to
      # @param query [Bluebook::Query] the query being rendered
      # @param fields [Array<Forms::Field>] the resolved field tree, for the parameter list
      # @return [String] the `<details>` panel markup
      def self.inspect_panel(domain, aggregate, query, fields)
        verb = "#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}"
        paths = Params.paths(fields)
        <<~HTML
          <details class="inspect">
            <summary>Inspect — #{Escape.html(verb)}</summary>
            <p>Parameters: #{paths.empty? ? '<em>none</em>' : paths.map { |p| "<code>#{Escape.html(p)}</code>" }.join(', ')}</p>
            <pre>#{Escape.html(JSON.pretty_generate(query.to_h))}</pre>
          </details>
        HTML
      end
    end
  end
end
