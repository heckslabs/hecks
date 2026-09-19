require_relative "../vocabulary"

module Hecks
  module Runtime
    # Every DomainRefusal wording that is not already data — `given`/
    # `ensures`/a declared `invariant` already carry their own description,
    # read at dispatch time off the command or value object that declared
    # them. These are different in kind: language-level refusals, the same
    # wording for every domain, not authored per-bluebook.
    #
    # Read off the generated table, not typed a second time. The rows are
    # Vocabulary::RefusalTemplate (language/bluebook/vocabulary.bluebook),
    # projected into lib/hecks/vocabulary.rb by bin/project_vocabulary and
    # into rust/src/kernel/vocab/refusal_template.rs by
    # bin/project_rust_vocabulary; both regenerations are diffed in CI, so
    # there is no hand copy left here to drift. Declared order is kept.
    #
    # **The arguments are data too**. Vocabulary::RefusalSiteArgument names the
    # values each site takes and how each is written (a list's separator,
    # its sort, its empty reading, its quoting). Call sites use
    # `render_site` and hand over raw values; the Rust kernel's typed
    # `render_args` applies the same rows, and the projection that writes it
    # pins every site's output against `format_argument`/`substitute` here.
    module RefusalWording
      TEMPLATES = Hecks::Vocabulary.rows("RefusalTemplate")
                                   .to_h { |row| [[row["refusal"], row["site"]].freeze, row["template"]] }
                                   .freeze

      SHAPES   = %w[scalar list].freeze
      QUOTINGS = %w[none inspect].freeze

      module_function

      # Plain text substitution, never expression syntax — a template is
      # read, not evaluated. Values arrive already formatted; prefer
      # `render_site`, which formats them off the declared rows.
      def render(refusal, site, **values)
        substitute(template(refusal, site), values)
      end

      # The one door call sites use: exactly the arguments the site
      # declares (a missing or undeclared one raises ArgumentError before
      # any wording exists), each formatted by its RefusalSiteArgument row,
      # substituted in declared order.
      #
      #   RefusalWording.render_site("UnknownArgument", "unknown_args",
      #                              command: "Close", unknown: [:parcel], declared: [])
      #   # => "Close does not declare parcel — it takes none"
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

      # `render_site` without the registry lookups: a template, its
      # argument rows, and raw values. The Rust projection calls this with
      # the chapter's own rows to compute the expected wording it pins.
      def render_with(template, specs, arguments)
        values = specs.to_h do |spec|
          name = spec["argument"].to_sym
          [name, format_argument(spec, arguments.fetch(name))]
        end
        substitute(template, values)
      end

      # One argument, written the way its row says. A list is sorted first
      # (before quoting), then each item quoted, then joined; an empty list
      # reads `when_empty`. A scalar is quoted or taken as its own text.
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

      # Read lazily, not into a constant: bin/project_vocabulary boots
      # `hecks` (and so this file) before it writes the table a newly
      # declared site's rows live in.
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
