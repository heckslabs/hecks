module Hecksagain
  module Bluebook
    module MetaValidator
      # S14, ADR 0026 — DISPATCHES THE LANGUAGE'S OWN GRAMMAR TABLE INTO
      # ITSELF, once, so `Keyword`/`Argument`'s own `status` genuinely IS a
      # lifecycle — checked at real dispatch time (the same admission/
      # coercion/lifecycle-guard door every other command goes through),
      # not merely declared and never exercised.
      #
      # THE SOURCE STAYS STATIC. `syntax.bluebook`'s own `KeywordSeed`/
      # `ArgumentSeed` (still ~106/~178 hand-written `member` rows —
      # nothing about them needed rewriting) are what gets WRITTEN ; this
      # is what turns them into what gets READ. `Judge`/`Reconstruction`
      # already draw exactly this line everywhere else in the meta-domain
      # (a chapter's own DECLARATIONS versus what gets DISPATCHED from
      # them) — this runs the same distinction one level further out, for
      # the language's own grammar table.
      #
      # A DEDICATED RUNTIME, not `MetaValidator.fresh_runtime`. That one
      # is reserved for `Judge`'s own bootstrap (dispatching a CHAPTER's
      # declarations INTO the meta-domain's grammar) — a different act
      # from this one (dispatching the meta-domain's OWN grammar table
      # data into a live "Bluebook" domain instance). Sharing the runtime
      # would let one boot's own repository state leak into the other's.
      #
      # Usage:
      #
      #   MetaValidator.syntax_table  # => { keywords: [...], arguments: [...] }
      #
      # each row a plain Hash, string values, `status` included — the
      # exact shape `ParserTable`/`syntax_conformance_spec` already read
      # off the OLD closed-set members, so neither consumer had to change
      # what it does with a row, only where the row comes from.
      module SyntaxBoot
        module_function

        # Memoized the same way `MetaValidator.grammar_registry` itself
        # is — the ~284-command dispatch sequence below is real work, not
        # something three separate callers (ParserTable, syntax_
        # conformance_spec, bin/reference) should each pay for on every
        # call.
        def call
          @call ||= boot
        end

        def boot
          bluebook = MetaValidator.grammar_registry.bluebook("Bluebook")
          # `MetaValidator.fresh_runtime`, not a brand-new `Runtime::
          # Registry` — the grammar registry's own copy already has
          # "Bluebook" registered (`grammar_registry`'s own boot already
          # ran `registry.add_bluebook`) AND its adapter ports already
          # loaded ; a standalone registry would need both wired by hand.
          # `fresh_runtime` resets `@repositories` on the SAME registry —
          # the identical isolation `Judge.new` already relies on for
          # every real domain it judges, proven safe by every dispatch
          # this session has ever made.
          runtime = MetaValidator.fresh_runtime

          declare_syntax(runtime, bluebook)
          admit_keywords(runtime, bluebook)
          admit_arguments(runtime, bluebook)

          read_back(runtime, bluebook)
        end

        # An Integer stays an Integer — `position` is `Position`-typed
        # (`attribute :value, Integer`), so stringifying it fails the type
        # gate rather than feeding it, the same reading `Judge#v` gives.
        def v(text)
          return { value: text } if text.is_a?(Integer)

          { value: text.to_s }
        end

        # ABSENT STAYS ABSENT. A seed row's own optional columns ("was",
        # "at", "named", ...) are empty strings, not nil — `Literal`/CSV-
        # shaped grammar data has no `nil` to write — so this is the one
        # place that decides "" means "not given" for the purpose of an
        # `optional: true` command argument, the same reading `Judge#v`
        # makes for the meta-domain's own dispatches.
        def optional(text)
          return nil if text.nil? || text.to_s.empty?

          v(text)
        end

        # `Syntax.Declare`'s own `reference_to Bluebook` names the CHAPTER
        # it belongs to — the same fact every other top-level aggregate's
        # own creating command carries (`ProcessManager.Declare`,
        # `Policy.Declare`, ...). This fresh runtime holds no chapter
        # record of its own yet (nothing else here needs one), so one is
        # declared first, named after the real chapter, purely to satisfy
        # the reference — its own vision/classification are never read
        # by anything this boot does.
        def declare_syntax(runtime, bluebook)
          syntax = bluebook.aggregate("Syntax")
          runtime.dispatch("Bluebook::Bluebook.Declare", name:           v(bluebook.hecks_name),
                                                         vision:         v("the language's own grammar table, dispatched into itself"),
                                                         classification: v("core"))
          runtime.dispatch("Bluebook::Syntax.Declare", bluebook: bluebook.hecks_name, name: v(syntax.hecks_name))
        end

        def admit_keywords(runtime, bluebook)
          all_rows(bluebook, "KeywordSeed").each_with_index do |row, index|
            runtime.dispatch("Bluebook::Syntax.Keyword",
                             name: v("Syntax"), position: v(index),
                             word: v(row[:word]), context: v(row[:context]), body: v(row[:body]),
                             inner: v(row[:inner]), opens: v(row[:opens]), fills: v(row[:fills]),
                             was: optional(row[:was]),
                             resolves_via: optional(row[:resolves_via]), disambiguator: optional(row[:disambiguator]))

            next unless row[:status].to_s == "deprecated"

            runtime.dispatch("Bluebook::Syntax.Keyword.Deprecate", name: v("Syntax"), position: v(index))
          end
        end

        def admit_arguments(runtime, bluebook)
          all_rows(bluebook, "ArgumentSeed").each_with_index do |row, index|
            runtime.dispatch("Bluebook::Syntax.Argument",
                             name: v("Syntax"), position: v(index),
                             keyword: v(row[:keyword]), context: v(row[:context]),
                             at: optional(row[:at]), named: optional(row[:named]),
                             kind: v(row[:kind]), required: v(row[:required]), fills: v(row[:fills]),
                             selects: optional(row[:selects]), pair_key_fills: optional(row[:pair_key_fills]),
                             pair_value_fills: optional(row[:pair_value_fills]),
                             pairs_shape: optional(row[:pairs_shape]), variadic: optional(row[:variadic]))

            next unless row[:status].to_s == "deprecated"

            runtime.dispatch("Bluebook::Syntax.Argument.Deprecate", name: v("Syntax"), position: v(index))
          end
        end

        # THE CORE'S OWN ROWS, THEN EVERY ATTACHED CHAPTER'S — ADR 0026's
        # own seam. `attached_chapters` finds them by what they declared
        # about THEMSELVES (`attaches_to`), never by name, so a new
        # sub-language needs nothing added here to be found. Concatenated
        # into ONE sequence, not dispatched chapter-by-chapter, because
        # `position` is minted from the walk index below and every
        # admitted row — wherever it came from — needs one that does not
        # collide with any other.
        def all_rows(bluebook, name)
          rows(bluebook, name) + attached_chapters.flat_map { |chapter| rows(chapter, name) }
        end

        # EVERY OTHER CHAPTER THE GRAMMAR REGISTRY HOLDS that named a core
        # context onto itself — the core never names Paging back; Paging
        # named the core. `bluebook` itself is excluded by construction:
        # it declares no `attaches_to` of its own to be found by.
        def attached_chapters
          MetaValidator.grammar_registry.bluebooks.values.select { |chapter| chapter.attaches_to.any? }
        end

        # The seed rows themselves — plain hashes, string values, read
        # straight off the still-static `KeywordSeed`/`ArgumentSeed`
        # closed sets exactly the way `ParserTable`'s own OLD `rows`
        # method always did. Absent from a chapter with no `Syntax`
        # aggregate of that name at all (most attached chapters will
        # only ever declare one, but nothing requires it).
        def rows(bluebook, name)
          syntax = bluebook.aggregate("Syntax")
          return [] unless syntax

          value_object = syntax.value_objects.find { |vo| vo.hecks_name == name }
          return [] unless value_object

          value_object.members.map { |row| row.to_h.transform_values(&:to_s) }
        end

        # Reads the dispatched result back into the SAME shape `rows`
        # above hands the seed data in as — plain hashes, string values,
        # `status` included — so `ParserTable`/`syntax_conformance_spec`
        # need not know or care that a real dispatch happened in between.
        def read_back(runtime, bluebook)
          syntax = bluebook.aggregate("Syntax")
          repository = runtime.registry.repository("Bluebook", syntax)
          instance   = repository.find(Naming.identity([syntax.hecks_name]))

          {
            keywords:  Array(instance[:keywords]).map { |row| stringify(row) },
            arguments: Array(instance[:arguments]).map { |row| stringify(row) }
          }
        end

        def stringify(row)
          row.to_h.each_with_object({}) do |(key, cell), out|
            out[key] = scalar(cell).to_s
          end
        end

        def scalar(cell)
          return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

          cell
        end
      end
    end
  end
end
