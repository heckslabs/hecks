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
      # Lists every field a command's form shows: the `to` identity picker first (unless the
      # command creates its aggregate), then one field per command attribute.
      #
      # The same field list a POST handler needs to cast raw params against
      # (params.rb's `Params.extract`) — one derivation, so a page never
      # renders an input the submit handler doesn't also expect.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares the command
      # @param command [Bluebook::Command] the command the form submits
      # @return [Array<Forms::Field>] the form's top-level fields, in render order
      # @raise [Bluebook::DSL::Malformed] if a `reference_to` attribute cannot say which
      #   aggregate declares it
      def self.fields_for(aggregate, command)
        addressing = command.creates? ? [] : [identity_field(aggregate)]
        addressing + command.attributes.map { |a| FieldShape.resolve(a, aggregate: aggregate) }
      end

      # Renders the page body for one command: header, refusal banner, the form itself, and
      # the inspect panel.
      #
      # `registry` serves only to populate a `:reference` field's
      # `<select>` with real records (including the identity picker itself,
      # for a non-creating command — see `identity_field` below). `values`/
      # `error` carry a sticky re-render after a refused submission; leave
      # both nil for a fresh form. `prefill` carries values a caller
      # arrived with (typically `?to=...` off a record's own detail page) —
      # kept separate from `values` because a prefill is not an error retry
      # and should not be treated as one by a future reader of this code.
      #
      # @param registry [Runtime::Registry] the booted registry, read for reference options
      # @param domain [String] name of the domain (chapter) the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares the command
      # @param command [Bluebook::Command] the command the form submits
      # @param action [String] URL path the form posts to
      # @param values [Hash{String => Object}, nil] the raw submission to re-show after a
      #   refusal, keyed by dotted field path; nil falls back to `prefill`
      # @param error [Exception, nil] the refusal to show in the banner; nil for a fresh form
      # @param prefill [Hash{String => String}] values the caller arrived with, keyed by
      #   dotted field path; ignored when `values` is given
      # @return [String] the HTML page body, without the surrounding page chrome
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

      # Builds the `to` field a non-creating command uses to name the record it acts on,
      # labelled with the aggregate's identity paths.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose records the picker offers
      # @return [Forms::Field] a `:reference` field at path `"to"` targeting `aggregate`
      def self.identity_field(aggregate)
        Field.new(path: "to", label: "#{aggregate.hecks_name} (#{aggregate.identity_paths.join(', ')})",
                  kind: :reference, html_type: "text", target_aggregate: aggregate,
                  help: "The record this command acts on.")
      end

      # Renders the form's heading: the command's qualified name, its role and creates
      # badges, its goal, and its preconditions callout.
      #
      # @param domain [String] name of the domain (chapter) the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares the command
      # @param command [Bluebook::Command] the command being described
      # @return [String] HTML for the heading block
      def self.header(domain, aggregate, command)
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}")}</h1>
          #{%(<span class="badge role" title="Declared on the command; this prototype dispatches with no caller bound, so the check does not run.">role: #{Escape.html(command.role)} (not enforced here)</span>) if command.role}
          #{%(<span class="badge">creates a new #{Escape.html(aggregate.hecks_name)}</span>) if command.creates?}
          #{%(<p class="goal">#{Escape.html(command.goal)}</p>) if command.goal}
          #{givens_callout(command)}
        HTML
      end

      # Renders the command's `given` preconditions as a callout, so a caller sees what
      # would refuse the submission before making it.
      #
      # @param command [Bluebook::Command] the command whose givens are listed
      # @return [String] HTML for the callout, or `""` when the command declares no givens
      def self.givens_callout(command)
        return "" if command.givens.empty?

        items = command.givens.map { |given| "<li>#{Escape.html(given.description)}</li>" }
        %(<div class="callout"><strong>Preconditions</strong> — refused if any fail:<ul>#{items.join}</ul></div>)
      end

      # Renders a refused submission as an alert banner carrying the refusal's class name
      # (without its namespace) and message.
      #
      # @param error [Exception, nil] the refusal raised by the submission
      # @return [String] HTML for the banner, or `""` when `error` is nil
      def self.error_banner(error)
        return "" unless error

        <<~HTML
          <div class="error-banner" role="alert">
            <p><strong>#{Escape.html(error.class.name.split('::').last)}</strong> — #{Escape.html(error.message)}</p>
          </div>
        HTML
      end

      # Maps a refusal to per-field messages; always empty, so every refusal is shown in
      # the banner rather than beside a field.
      #
      # No structured field attribution exists on a domain refusal today
      # (it is a typed exception with a rendered message — see
      # docs/command-form-and-query-form-bluebook.md's note on
      # `RefusalWording`), so this returns empty rather than guessing which
      # field a message meant; the banner above carries the real text
      # instead of a misattributed hint.
      #
      # @param _error [Exception, nil] the refusal raised by the submission; ignored
      # @return [Hash] always empty; keys would be dotted field paths
      def self.field_errors(_error) = {}

      # Renders the collapsed "Inspect" panel: the events the command emits, an equivalent
      # `curl` request, its field paths, and its declaration as JSON.
      #
      # @param domain [String] name of the domain (chapter) the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares the command
      # @param command [Bluebook::Command] the command being described
      # @param action [String] URL path the form posts to, shown in the `curl` line
      # @param fields [Array<Forms::Field>] the form's fields, as `fields_for` returns them
      # @return [String] HTML for the `<details>` panel
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
