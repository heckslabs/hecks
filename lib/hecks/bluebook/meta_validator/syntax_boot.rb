module Hecks
  module Bluebook
    module MetaValidator
      # S14, ADR 0026 — DISPATCHES THE LANGUAGE'S OWN GRAMMAR TABLE INTO
      # ITSELF, once, so `Keyword`/`Argument`'s own `status` genuinely IS a
      # lifecycle — checked at real dispatch time (the same admission/
      # coercion/lifecycle-guard door every other command goes through),
      # not merely declared and never exercised.
      #
      # THE SOURCE STAYS STATIC. Aggregate-local `KeywordSeed`/
      # `ArgumentSeed` value objects (still hand-written `member` rows —
      # now beside the concepts they spell) are what gets WRITTEN ; this
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
        #
        # KEYED BY THE GRAMMAR REGISTRY'S OWN CHAPTER SET, not by a
        # "ready" flag. `boot` reads exactly two things: the registry's
        # "Bluebook" chapter (the core seed rows) and every chapter in the
        # registry that `attaches_to` a core context (Paging's rows). So
        # the table is a pure function of which chapter OBJECTS the
        # registry holds — and that is the cache key: the same chapters,
        # by identity, mean the same table; a chapter replaced (the
        # fixpoint judge swapping a raw chapter for its assembled self)
        # or added (`load_attached_grammar_into`) means a fresh boot.
        #
        # WHY NOT THE EARLIER `grammar_registry_ready?` GUARD. That guard
        # was right about the hazard — a snapshot taken mid-build, before
        # Paging attached, would be missing limit/offset/cursor/nulls
        # forever — and wrong about the cost of its cure. It refused to
        # cache ANYTHING until the whole grammar registry had finished
        # building, calling that window "narrow" and recomputing in it
        # "cheap". Measured (hecks_ai_training, a six-entity chess domain,
        # 2026-08-22): every `word_gate_dispatch` landing in that window
        # re-ran the full ~284-dispatch boot at ~0.76s each — 42 times per
        # process, 32 of a 35-second `Hecks.boot`, 95% of which had
        # nothing to do with the domain being booted. Keying on the
        # chapter set closes the same hazard by construction (a snapshot
        # can only be served while the chapters it was read from are
        # still the chapters the registry holds) and lets the window's
        # own repeated, identical calls share one boot. A registry reset
        # (fixpoint_spec's own `@grammar_registry = nil`) yields new
        # chapter objects, so it invalidates this the same way it always
        # invalidated `grammar_registry_ready?`.
        #
        # `equal?`, NOT `==`, on the chapters — identity is the fact being
        # tracked. Holding the chapter objects themselves (not their ids)
        # in the key also means a collected chapter can never hand its id
        # to a newcomer behind this cache's back.
        def call
          chapters = MetaValidator.grammar_registry.bluebooks.to_a
          return @call if @call && same_chapters?(@call_chapters, chapters)

          result = boot
          @call = result
          @call_chapters = chapters
          result
        end

        def same_chapters?(cached, current)
          cached.size == current.size &&
            cached.zip(current).all? do |(cached_name, cached_chapter), (name, chapter)|
              cached_name == name && cached_chapter.equal?(chapter)
            end
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
                                                         vision:         v("the language's own grammar table, " \
                                                                           "dispatched into itself"),
                                                         classification: v("core"))
          runtime.dispatch("Bluebook::Syntax.Declare", bluebook: bluebook.hecks_name, name: v(syntax.hecks_name))
        end

        # `to: "Syntax"` NAMES THE RECORD ALREADY OPENED BY `declare_syntax`
        # ABOVE — an append onto an existing aggregate, not a second creation
        # of it. This used to smuggle `name: v("Syntax")` into the payload
        # instead, the pre-routing convention `Judge#appends` (the same
        # append shape, for `ValueObject.Member`/`ProcessManager.Handler`)
        # already left behind for `to:`/`with:` — carrying the receiver in
        # the payload made `Syntax.Keyword`'s own `command.creates?` (true:
        # it declares no `reference_to`) look like a fresh identity to mint,
        # which collided with the very "Syntax" row `declare_syntax` had
        # just opened.
        def admit_keywords(runtime, bluebook)
          all_rows(bluebook, "KeywordSeed").each_with_index do |row, index|
            runtime.dispatch("Bluebook::Syntax.Keyword", to:   "Syntax",
                                                         with: { position: v(index),
                                     word: v(row[:word]), context: v(row[:context]), body: v(row[:body]),
                                     inner: v(row[:inner]), opens: v(row[:opens]), fills: v(row[:fills]),
                                     was: optional(row[:was]),
                                     resolves_via: optional(row[:resolves_via]),
                                     disambiguator: optional(row[:disambiguator]),
                                     calls: optional(row[:calls]) })

            next unless row[:status].to_s == "deprecated"

            runtime.dispatch("Bluebook::Syntax.Keyword.Deprecate", to: { aggregate: "Syntax", entity: index.to_s })
          end
        end

        def admit_arguments(runtime, bluebook)
          all_rows(bluebook, "ArgumentSeed").each_with_index do |row, index|
            runtime.dispatch("Bluebook::Syntax.Argument", to:   "Syntax",
                                                          with: { position: v(index),
                                     keyword: v(row[:keyword]), context: v(row[:context]),
                                     at: optional(row[:at]), named: optional(row[:named]),
                                     kind: v(row[:kind]), required: v(row[:required]), fills: v(row[:fills]),
                                     selects: optional(row[:selects]), pair_key_fills: optional(row[:pair_key_fills]),
                                     pair_value_fills: optional(row[:pair_value_fills]),
                                     pairs_shape: optional(row[:pairs_shape]), variadic: optional(row[:variadic]),
                                     minimum: optional(row[:minimum]),
                                     coerce: optional(row[:coerce]), blank_message: optional(row[:blank_message]) })

            next unless row[:status].to_s == "deprecated"

            runtime.dispatch("Bluebook::Syntax.Argument.Deprecate", to: { aggregate: "Syntax", entity: index.to_s })
          end
        end

        # EVERY AGGREGATE-LOCAL TABLE IN EVERY LOADED LANGUAGE CHAPTER.
        # The table's presence is the registration: no chapter, aggregate,
        # filename, or context catalog is maintained here. This finds the core
        # Bluebook concepts, the sibling artifact languages (World, Hecksagon,
        # Port, Adapter, Translation), and attached sub-languages alike.
        # Concatenated into ONE sequence because `position` is minted from the
        # walk index and must not collide across concepts.
        def all_rows(bluebook, name)
          seed_chapters(bluebook).flat_map { |chapter| rows(chapter, name) }
        end

        # Keep the core chapter first, then registry insertion order for every
        # sibling/extension. The name rejection avoids reading the same core
        # object twice without relying on object identity across fixpoint
        # assembly.
        def seed_chapters(bluebook)
          [bluebook] + MetaValidator.grammar_registry.bluebooks.values.reject { |chapter| chapter.name == bluebook.name }
        end

        # The seed rows themselves — plain hashes, string values, read from
        # every aggregate that owns a same-named local value object. Repeating
        # the value-object shape is deliberate: each concept remains readable
        # by itself, while this discovery is the only grouping mechanism.
        def rows(bluebook, name)
          bluebook.aggregates.flat_map do |aggregate|
            value_object = aggregate.value_objects.find { |vo| vo.hecks_name == name }
            next [] unless value_object

            value_object.members.map { |row| row.to_h.transform_values(&:to_s) }
          end
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
          row.to_h.transform_values do |cell|
            scalar(cell).to_s
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
