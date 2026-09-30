require_relative "../vocabulary"

module Hecks
  module Runtime
    # Language-level DomainRefusal wording, the same for every domain.
    # Templates and argument formats are read from the generated Vocabulary tables.
    module RefusalWording
      TEMPLATES = Hecks::Vocabulary.rows("RefusalTemplate")
                                   .to_h { |row| [[row["refusal"], row["site"]].freeze, row["template"]] }
                                   .freeze

      SHAPES   = %w[scalar list].freeze
      QUOTINGS = %w[none inspect].freeze

      module_function

      # Renders `refusal`/`site`'s template, substituting already-formatted `values`.
      def render(refusal, site, **values)
        substitute(template(refusal, site), values)
      end

      # Whether `reason` is the AlreadyExists refusal for a duplicate creation, matched by the
      # template's own wording so a remote host's reason reads the same as a local one.
      #
      # @param reason [String, nil] the refusal message
      # @return [Boolean]
      def already_exists?(reason)
        @already_exists ||= begin
          parts = TEMPLATES.fetch(%w[AlreadyExists creating_duplicate]).split(/\{\w+\}/, -1)
          Regexp.new("\\A#{parts.map { |part| Regexp.escape(part) }.join('.*')}\\z", Regexp::MULTILINE)
        end
        @already_exists.match?(reason.to_s)
      end

      # Renders a site's template from raw `arguments`, formatting each per its row.
      # Raises ArgumentError on a missing or undeclared argument, KeyError on an unknown site.
      def render_site(refusal, site, **arguments)
        specs    = argument_rows(refusal, site)
        declared = specs.map { |spec| spec["argument"].to_sym }
        missing  = declared - arguments.keys
        extra    = arguments.keys - declared
        if missing.any? || extra.any?
          raise ArgumentError, "#{refusal}/#{site} takes #{declared.join(', ')} — " \
                               "missing: #{missing.join(', ')}; undeclared: #{extra.join(', ')}"
        end

        render_with(template(refusal, site), specs, arguments)
      end

      # `render_site` without the registry lookups; the Rust projection calls it with its own rows.
      def render_with(template, specs, arguments)
        values = specs.to_h do |spec|
          name = spec["argument"].to_sym
          [name, format_argument(spec, arguments.fetch(name))]
        end
        substitute(template, values)
      end

      # A list is sorted, then quoted, then joined; an empty list reads `when_empty`.
      def format_argument(spec, value)
        inspect = spec.fetch("quoting") == "inspect"
        return inspect ? value.inspect : value.to_s unless spec.fetch("shape") == "list"

        items = Array(value)
        items = items.sort if spec.fetch("sorted") == "true"
        items = items.map(&:inspect) if inspect
        items.empty? ? spec.fetch("when_empty") : items.join(spec.fetch("separator"))
      end

      def substitute(template, values)
        values.reduce(template) { |text, (key, value)| text.gsub("{#{key}}", value.to_s) }
      end

      def template(refusal, site)
        TEMPLATES.fetch([refusal, site]) do
          raise KeyError, "no refusal template for #{refusal}/#{site} — declare it in " \
                          "Vocabulary::RefusalTemplate first"
        end
      end

      # Read lazily: bin/project_vocabulary boots this file before it writes these rows.
      def argument_rows(refusal, site)
        @argument_rows ||= Hecks::Vocabulary.rows("RefusalSiteArgument")
                                            .group_by { |row| [row["refusal"], row["site"]] }
                                            .transform_values(&:freeze)
                                            .freeze
        @argument_rows.fetch([refusal, site]) do
          raise KeyError, "no refusal arguments for #{refusal}/#{site} — declare them in " \
                          "Vocabulary::RefusalSiteArgument first"
        end
      end
    end
  end
end
