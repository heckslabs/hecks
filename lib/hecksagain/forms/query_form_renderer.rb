require "json"
require "uri"
require_relative "html"
require_relative "field_shape"
require_relative "field_renderer"
require_relative "reference_options"
require_relative "params"
require_relative "record_table"

module Hecksagain
  module Forms
    # Query -> the page body for its GET view — the working half of what
    # `query_form.bluebook` names (see docs/command-form-and-query-form-
    # bluebook.md): a canonical, shareable link (queries are GETs — every
    # one of them is already a URL, so this says so up front rather than
    # hiding that behind a form); a row of ready-made links for any
    # closed-set parameter, since a caller filtering by an enum should not
    # have to fill in a form to get a link they could just click; a filter
    # FORM for everything else, which — being a GET form — produces
    # exactly the same kind of link on submit; and the results table once
    # a request actually supplies parameters.
    module QueryFormRenderer
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

      def self.header(domain, aggregate, query)
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}.#{query.hecks_name}")}</h1>
          #{query.description ? %(<p class="goal">#{Escape.html(query.description)}</p>) : ''}
          #{badges(query)}
        HTML
      end

      def self.badges(query)
        parts = []
        parts << %(<span class="badge">consistency: #{Escape.html(fmt(query.consistency&.to_h))}</span>) if query.consistency
        parts << %(<span class="badge">freshness: #{Escape.html(fmt(query.freshness&.to_h))}</span>) if query.freshness
        parts << %(<span class="badge">limit #{Escape.html(query.limit.to_h[:value])}</span>) if query.limit
        parts.join
      end

      def self.fmt(hash) = (hash || {}).map { |k, v| "#{k}=#{v}" }.join(" ")

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
      # ones". Capped at the FIRST closed-set field on purpose: a second one
      # would mean a cross product of links, which reads as noise rather
      # than help. A query with more than one is still fully reachable
      # through the filter form below.
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

        %(<div class="error-banner" role="alert"><p><strong>#{Escape.html(error.class.name.split('::').last)}</strong> — #{Escape.html(error.message)}</p></div>)
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
            <p>Parameters: #{paths.empty? ? '<em>none</em>' : paths.map { |p| "<code>#{Escape.html(p)}</code>" }.join(', ')}</p>
            <pre>#{Escape.html(JSON.pretty_generate(query.to_h))}</pre>
          </details>
        HTML
      end
    end
  end
end
