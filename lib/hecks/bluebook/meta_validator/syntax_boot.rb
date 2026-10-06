require "digest"
require "fileutils"
require_relative "../../cache_dir"
require_relative "syntax_boot/disk_cache"

module Hecks
  module Bluebook
    module MetaValidator
      # Dispatches the language's own grammar table through a real runtime so
      # `Keyword`/`Argument` status is a lifecycle, not just declared (ADR 0026).
      #
      #   SyntaxBoot.call # => { keywords: [...], arguments: [...] }
      module SyntaxBoot
        extend DiskCache

        module_function

        # Memoized per grammar-registry chapter set (identity, not a "ready"
        # flag), and cross-process on disk, since a full boot is real work.
        #
        # @return [Hash{Symbol => Array<Hash{Symbol => String}>}] `:keywords`
        #   and `:arguments`, each an array of plain, string-valued row
        #   hashes (`status` included)
        def call
          chapters = MetaValidator.grammar_registry.bluebooks.to_a
          return @call if @call && same_chapters?(@call_chapters, chapters)

          result = read_disk_cache(chapters) || begin
            fresh = boot
            write_disk_cache(chapters, fresh)
            fresh
          end

          @call = result
          @call_chapters = chapters
          result
        end

        # Dispatches every seed row into a fresh "Bluebook" instance and
        # reads the result back.
        def boot
          bluebook = MetaValidator.grammar_registry.bluebook("Bluebook")
          # `fresh_runtime`, not a new `Runtime::Registry` — the grammar
          # registry already has "Bluebook" registered and its adapter
          # ports already loaded.
          runtime = MetaValidator.fresh_runtime

          declare_syntax(runtime, bluebook)
          admit_keywords(runtime, bluebook)
          admit_arguments(runtime, bluebook)

          read_back(runtime, bluebook)
        end

        # An Integer stays an Integer — `position` is `Position`-typed, so
        # stringifying it would fail the type gate rather than feed it.
        def v(text)
          return { value: text } if text.is_a?(Integer)

          { value: text.to_s }
        end

        # A seed row's own optional columns are "", not nil (CSV-shaped
        # grammar data has no nil to write) — this is where "" is read as
        # "not given".
        def optional(text)
          return nil if text.nil? || text.to_s.empty?

          v(text)
        end

        # This fresh runtime holds no chapter record of its own, so one is
        # declared first, purely to satisfy `Syntax.Declare`'s `reference_to
        # Bluebook` — its vision/classification are never read afterward.
        def declare_syntax(runtime, bluebook)
          syntax = bluebook.aggregate("Syntax")
          runtime.dispatch("Bluebook::Bluebook.Declare",
                           with: { name:           v(bluebook.hecks_name),
                                   vision:         v("the language's own grammar table, " \
                                                     "dispatched into itself"),
                                   classification: v("core") })
          runtime.dispatch("Bluebook::Syntax.Declare",
                           with: { bluebook: bluebook.hecks_name, name: v(syntax.hecks_name) })
        end

        # Each Keyword seed column and how it is offered: `v` for a required cell, `optional` for
        # one whose "" means "not given".
        KEYWORD_COLUMNS = {
          word: :v, context: :v, body: :v, inner: :v, opens: :v, fills: :v,
          was: :optional, resolves_via: :optional, disambiguator: :optional, calls: :optional
        }.freeze

        # The same, for each Argument seed column.
        ARGUMENT_COLUMNS = {
          keyword: :v, context: :v, at: :optional, named: :optional, kind: :v, required: :v, fills: :v,
          selects: :optional, pair_key_fills: :optional, pair_value_fills: :optional,
          pairs_shape: :optional, variadic: :optional, minimum: :optional,
          coerce: :optional, blank_message: :optional
        }.freeze

        def admit_keywords(runtime, bluebook) = admit(runtime, bluebook, "Keyword", KEYWORD_COLUMNS)

        # Same `to: "Syntax"` append shape `admit_keywords` uses, one type over.
        def admit_arguments(runtime, bluebook) = admit(runtime, bluebook, "Argument", ARGUMENT_COLUMNS)

        # `to: "Syntax"` appends onto the record `declare_syntax` already
        # opened; putting the receiver in the payload instead would make
        # `Syntax.Keyword` look like a fresh identity to mint, colliding
        # with that row.
        def admit(runtime, bluebook, kind, columns)
          all_rows(bluebook, "#{kind}Seed").each_with_index do |row, index|
            runtime.dispatch("Bluebook::Syntax.#{kind}", to: "Syntax", with: seed_payload(row, index, columns))

            next unless row[:status].to_s == "deprecated"

            runtime.dispatch("Bluebook::Syntax.#{kind}.Deprecate", to: { aggregate: "Syntax", entity: index.to_s })
          end
        end

        # The walk index first, then each column offered the way `columns` says.
        def seed_payload(row, index, columns)
          columns.each_with_object({ position: v(index) }) do |(column, offering), payload|
            payload[column] = send(offering, row[column])
          end
        end

        # Concatenated into one sequence because `position` is minted from
        # the walk index and must not collide across concepts.
        def all_rows(bluebook, name)
          seed_chapters(bluebook).flat_map { |chapter| rows(chapter, name) }
        end

        # `bluebook` first, then registry insertion order, so the core
        # chapter is never read twice.
        def seed_chapters(bluebook)
          [bluebook] + MetaValidator.grammar_registry.bluebooks.values.reject { |chapter| chapter.name == bluebook.name }
        end

        def rows(bluebook, name)
          bluebook.aggregates.flat_map do |aggregate|
            value_object = aggregate.value_objects.find { |vo| vo.hecks_name == name }
            next [] unless value_object

            value_object.members.map { |row| row.to_h.transform_values(&:to_s) }
          end
        end

        # Reads the dispatched result back into the same plain-hash shape
        # `rows` hands the seed data in as.
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

        # Unwraps a value-object-wrapped field back to its bare scalar.
        def scalar(cell)
          return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

          cell
        end
      end
    end
  end
end
