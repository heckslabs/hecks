require "json"
require_relative "html"
require_relative "field_shape"
require_relative "field_renderer"
require_relative "reference_options"
require_relative "params"

module Hecks
  module Forms
    # Renders a command as the page body of its HTML form; no per-command code
    # (see docs/command-form-and-query-form-bluebook.md).
    module CommandFormRenderer
      # Lists every field a command's form shows: the `to` identity picker first (unless the
      # command creates its aggregate), then one field per command attribute.
      #
      # The same list `Params.extract` casts a POST against, so a page never renders
      # an input the submit handler does not expect.
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
      # `registry` populates `:reference` selects. `values` and `error` re-render after a
      # refusal; `prefill` carries values the caller arrived with (`?to=...`), not a retry.
      #
      # @param registry [Runtime::Registry] the booted registry, read for reference options
      # @param action [String] URL path the form posts to
      # @param values [Hash{String => Object}, nil] raw submission to re-show; nil uses `prefill`
      # @param error [Exception, nil] the refusal to show in the banner; nil for a fresh form
      # @param prefill [Hash{String => String}] values the caller arrived with, by dotted path
      # @return [String] the HTML page body, without the surrounding page chrome
      def self.render(registry:, domain:, aggregate:, command:, **form)
        all_fields = fields_for(aggregate, command)
        fields_html = fields_markup(registry, domain, all_fields, form)
        action = form.fetch(:action)
        cancel = "/#{domain}/#{aggregate.hecks_name}"
        [header(aggregate, command), error_banner(form[:error]),
         form_markup(action, fields_html, command, cancel).chomp,
         inspect_panel(domain, aggregate, command, action, all_fields)].join("\n").concat("\n")
      end

      # @param form [Hash] the submission being re-shown: `values:`, `error:` and `prefill:`
      # @return [String] every field's HTML, populated from the submission or the prefill
      def self.fields_markup(registry, domain, fields, form)
        reference_options = ReferenceOptions.collect(registry, domain, fields)
        shown_values = form[:values] || form.fetch(:prefill, {})
        fields.map do |f|
          FieldRenderer.render(f, values: shown_values, errors: field_errors(form[:error]), reference_options: reference_options)
        end.join
      end

      # @return [String] the `<form>` element: the fields, the submit button and the cancel link
      def self.form_markup(action, fields_html, command, cancel)
        <<~HTML
          <form method="post" action="#{Escape.attr(action)}" novalidate>
            #{fields_html}
            <div class="actions">
              <button type="submit">#{Escape.html(Humanize.phrase(command.hecks_name))}</button>
              <a class="button secondary" href="#{Escape.attr(cancel)}">Cancel</a>
            </div>
          </form>
        HTML
      end

      # Builds the `to` field a non-creating command uses to name the record it acts on,
      # labelled with the aggregate's name and helped by what identifies one ("the order's
      # name").
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose records the picker offers
      # @return [Forms::Field] a `:reference` field at path `"to"` targeting `aggregate`
      def self.identity_field(aggregate)
        noun = Humanize.noun(aggregate.hecks_name)
        Field.new(path: "to", label: Humanize.phrase(aggregate.hecks_name),
                  kind: :reference, html_type: "text", target_aggregate: aggregate,
                  help: "Which #{noun} this is for, by the #{noun}'s #{identity_words(aggregate)}.")
      end

      # Names what identifies a record in words: `["name.value"]` -> "name", a composite
      # `["bank", "number"]` -> "bank and number". A dotted path names its first segment,
      # since the hops after it reach inside a value object.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose identity is named
      # @return [String] the identity's field names as lowercase words; "id" when it has none
      def self.identity_words(aggregate)
        names = aggregate.identity_paths.map { |path| Humanize.noun(path.to_s.split(".").first) }.uniq
        names.empty? ? "id" : Naming.to_sentence_list(names)
      end

      # Renders the form's heading: the command's name in words, its role and creates
      # badges, its goal, and its preconditions callout. The code name stays in the inspect
      # panel.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares the command
      # @param command [Bluebook::Command] the command being described
      # @return [String] HTML for the heading block
      def self.header(aggregate, command)
        <<~HTML
          <h1>#{Escape.html(Humanize.phrase(command.hecks_name))}</h1>
          #{role_badge(command)}
          #{%(<span class="badge">Creates a new #{Escape.html(Humanize.noun(aggregate.hecks_name))}</span>) if command.creates?}
          #{%(<p class="goal">#{Escape.html(command.goal)}</p>) if command.goal}
          #{givens_callout(command)}
        HTML
      end

      # Names who the command is for. The preview dispatches with no caller bound, so the role
      # is shown but not checked, and the badge says so.
      #
      # @param command [Bluebook::Command] the command whose declared role is shown
      # @return [String] HTML for the badge, or `""` when the command declares no role
      def self.role_badge(command)
        return "" unless command.role

        title = "The bluebook declares who does this. This preview signs nobody in, so it does not check."
        %(<span class="badge role" title="#{title}">Done by: #{Escape.html(command.role)} (not checked in this preview)</span>)
      end

      # Renders the command's `given` preconditions as a callout, so a caller sees what
      # would refuse the submission before making it.
      #
      # @param command [Bluebook::Command] the command whose givens are listed
      # @return [String] HTML for the callout, or `""` when the command declares no givens
      def self.givens_callout(command)
        return "" if command.givens.empty?

        items = command.givens.map { |given| "<li>#{Escape.html(given.description)}</li>" }
        %(<div class="callout"><strong>Checked first.</strong> The action is refused if any of these fail:) \
          "<ul>#{items.join}</ul></div>"
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
            <p><strong>Refused (#{Escape.html(Naming.demodulise(error.class.name))}):</strong> #{Escape.html(error.message)}</p>
          </div>
        HTML
      end

      # Maps a refusal to per-field messages; always empty, so every refusal is shown in
      # the banner rather than beside a field.
      #
      # A domain refusal carries no field attribution, so the banner shows the message
      # instead of guessing a field.
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
        inspect_head(verb, command, curl_snippet(action, paths)) + inspect_tail(command, paths)
      end

      # @param action [String] URL path the form posts to
      # @param paths [Array<String>] the dotted field paths the request carries
      # @return [String] the `curl` call equivalent to submitting the form
      def self.curl_snippet(action, paths)
        <<~SH.strip
          curl -X POST '#{action}' \\
            #{paths.map { |path| "-d '#{path}=...'" }.join(" \\\n  ")}
        SH
      end

      # @param command [Bluebook::Command] the command whose emitted events are listed
      # @return [String] the events as `<code>` items, or a note that none are declared
      def self.emitted_events(command)
        return "<em>nothing declared</em>" if command.emits.empty?

        command.emits.map { |e| "<code>#{Escape.html(e)}</code>" }.join(", ")
      end

      # @return [String] the first half of the inspect panel: the summary, emitted events and the
      #   `curl` snippet
      def self.inspect_head(verb, command, curl)
        <<~HTML
          <details class="inspect">
            <summary>Inspect: #{Escape.html(verb)}</summary>
            <p>Emits: #{emitted_events(command)}</p>
            <p>The same request as <code>curl</code>. Every field is sent by its dotted path (<code>#{Escape.html("name.path")}</code>), as a form or as JSON:</p>
            <div class="link-row"><code id="curl-snippet">#{Escape.html(curl)}</code><button type="button" class="copy" data-copy="#curl-snippet">copy</button></div>
        HTML
      end

      # @return [String] the second half of the inspect panel: the field paths and the command's
      #   declaration as JSON
      def self.inspect_tail(command, paths)
        <<~HTML
            <p>Fields this command takes: #{paths.map { |p| "<code>#{Escape.html(p)}</code>" }.join(", ")}</p>
            <p>The command's own declaration, as the runtime holds it:</p>
            <pre>#{Escape.html(JSON.pretty_generate(command.to_h))}</pre>
          </details>
        HTML
      end
    end
  end
end
