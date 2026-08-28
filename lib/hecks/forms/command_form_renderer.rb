require "json"
require_relative "html"
require_relative "field_shape"
require_relative "field_renderer"
require_relative "reference_options"
require_relative "params"

module Hecks
  module Forms
    # Command -> the page body for its HTML form — the working half of
    # what `command_form.bluebook` names (see docs/command-form-and-query-
    # form-bluebook.md). Every command in every loaded, exposed bluebook
    # renders through here — nothing here is per-command code; see that
    # doc for the 1:1 rule this deliberately holds to for now.
    module CommandFormRenderer
      # `registry` is only used to populate a `:reference` field's
      # `<select>` with real records (including the identity picker itself,
      # for a non-creating command — see `identity_field` below). `values`/
      # `error` carry a sticky re-render after a refused submission; leave
      # both nil/`{}` for a fresh form. `prefill` carries values a caller
      # arrived WITH (typically `?to=...` off a record's own detail page) —
      # kept separate from `values` because a prefill is not an error retry
      # and should not be treated as one by a future reader of this code.
      # The SAME field list a POST handler needs to cast raw params against
      # (params.rb's `Params.extract`) — one derivation, so a page never
      # renders an input the submit handler doesn't also expect.
      def self.fields_for(aggregate, command)
        addressing = command.creates? ? [] : [identity_field(aggregate)]
        addressing + command.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
      end

      def self.render(registry:, domain:, aggregate:, command:, action:, values: nil, error: nil, prefill: {})
        all_fields = fields_for(aggregate, command)
        reference_options = ReferenceOptions.collect(registry, domain, all_fields)
        shown_values = values || prefill

        <<~HTML
          #{header(domain, aggregate, command)}
          #{error_banner(error)}
          <form method="post" action="#{Escape.attr(action)}" novalidate>
            #{all_fields.map { |f| FieldRenderer.render(f, values: shown_values, errors: field_errors(error), reference_options: reference_options) }.join}
            <div class="actions">
              <button type="submit">#{Escape.html(command.hecks_name)}</button>
              <a class="button secondary" href="#{Escape.attr("/#{domain}/#{aggregate.hecks_name}")}">Cancel</a>
            </div>
          </form>
          #{inspect_panel(domain, aggregate, command, action, all_fields)}
        HTML
      end

      def self.identity_field(aggregate)
        Field.new(path: "to", label: "#{aggregate.hecks_name} (#{aggregate.identity_paths.join(', ')})",
                  kind: :reference, html_type: "text", target_aggregate: aggregate,
                  help: "The record this command acts on.")
      end

      def self.header(domain, aggregate, command)
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}")}</h1>
          #{command.role ? %(<span class="badge role" title="Declared on the command; this prototype dispatches with no caller bound, so the check does not run.">role: #{Escape.html(command.role)} (not enforced here)</span>) : ''}
          #{command.creates? ? %(<span class="badge">creates a new #{Escape.html(aggregate.hecks_name)}</span>) : ''}
          #{command.goal ? %(<p class="goal">#{Escape.html(command.goal)}</p>) : ''}
          #{givens_callout(command)}
        HTML
      end

      def self.givens_callout(command)
        return "" if command.givens.empty?

        items = command.givens.map { |given| "<li>#{Escape.html(given.description)}</li>" }
        %(<div class="callout"><strong>Preconditions</strong> — refused if any fail:<ul>#{items.join}</ul></div>)
      end

      def self.error_banner(error)
        return "" unless error

        <<~HTML
          <div class="error-banner" role="alert">
            <p><strong>#{Escape.html(error.class.name.split('::').last)}</strong> — #{Escape.html(error.message)}</p>
          </div>
        HTML
      end

      # No structured field attribution exists on a domain refusal today
      # (it is a typed exception with a rendered message — see
      # docs/command-form-and-query-form-bluebook.md's note on
      # `RefusalWording`), so this returns empty rather than guessing which
      # field a message meant; the banner above carries the real text
      # instead of a misattributed hint.
      def self.field_errors(_error) = {}

      def self.inspect_panel(domain, aggregate, command, action, fields)
        verb = "#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}"
        paths = Params.paths(fields)
        curl = <<~SH.strip
          curl -X POST '#{action}' \\
            #{paths.map { |path| "-d '#{path}=...'" }.join(" \\\n  ")}
        SH
        <<~HTML
          <details class="inspect">
            <summary>Inspect — #{Escape.html(verb)}</summary>
            <p>Emits: #{command.emits.empty? ? '<em>nothing declared</em>' : command.emits.map { |e| "<code>#{Escape.html(e)}</code>" }.join(', ')}</p>
            <p>Equivalent request (as <code>curl</code>) — every field is <code>#{Escape.html('name.path')}</code>-encoded, form or JSON alike:</p>
            <div class="link-row"><code id="curl-snippet">#{Escape.html(curl)}</code><button type="button" class="copy" data-copy="#curl-snippet">copy</button></div>
            <p>Fields this command takes: #{paths.map { |p| "<code>#{Escape.html(p)}</code>" }.join(', ')}</p>
            <p>The command's own declaration, as the runtime holds it:</p>
            <pre>#{Escape.html(JSON.pretty_generate(command.to_h))}</pre>
          </details>
        HTML
      end
    end
  end
end
