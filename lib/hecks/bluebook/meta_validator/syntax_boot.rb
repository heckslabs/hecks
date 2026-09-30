require "digest"
require "fileutils"
require_relative "../../cache_dir"

module Hecks
  module Bluebook
    module MetaValidator
      # Dispatches the language's own grammar table through a real runtime so
      # `Keyword`/`Argument` status is a lifecycle, not just declared (ADR 0026).
      #
      #   SyntaxBoot.call # => { keywords: [...], arguments: [...] }
      module SyntaxBoot
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

        # `equal?`, not `==` — chapter identity, not value equality, is the
        # fact this cache key tracks.
        def same_chapters?(cached, current)
          cached.size == current.size &&
            cached.zip(current).all? do |(cached_name, cached_chapter), (name, chapter)|
              cached_name == name && cached_chapter.equal?(chapter)
            end
        end

        # Cross-process persistence for the same build `call` already memoizes
        # in-process, keyed by chapter name (not identity, which means nothing
        # across processes) plus a content hash of every grammar file `boot`
        # can read from — so a source edit anywhere in that set misses the
        # cache rather than silently serving a stale table.
        def cache_dir = Hecks::CacheDir.path("hecks_syntax_boot_cache")

        def disk_cache_enabled? = ENV["HECKS_SYNTAX_BOOT_CACHE"] != "off"

        # Fails toward a real boot, never toward a wrong table: a missing
        # file, a corrupt blob, or a permission error just misses the cache.
        def read_disk_cache(chapters)
          return nil unless disk_cache_enabled?

          path = disk_cache_path(chapters)
          return nil unless File.exist?(path)

          Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad -- own process-local cache, never external input
        rescue StandardError
          nil
        end

        # Writes to a PID-suffixed temp file and renames it into place, so a
        # concurrent writer's rename can only overwrite with identical
        # content, never leave a torn file for a concurrent reader.
        def write_disk_cache(chapters, result)
          return unless disk_cache_enabled?

          path = disk_cache_path(chapters)
          FileUtils.mkdir_p(cache_dir)
          tmp_path = "#{path}.#{Process.pid}.tmp"
          File.binwrite(tmp_path, Marshal.dump(result))
          File.rename(tmp_path, path)
        rescue StandardError
          nil
        end

        def disk_cache_path(chapters)
          File.join(cache_dir, "#{disk_cache_key(chapters)}.marshal")
        end

        def disk_cache_key(chapters)
          names = chapters.map { |name, _chapter| name }
          Digest::SHA256.hexdigest("#{names.join(',')}:#{grammar_content_digest}:#{VerdictCache.code_digest}")
        end

        # The key also carries `VerdictCache.code_digest` (all of `lib/`), so an
        # edit to Ruby that builds or judges the grammar misses too.
        #
        # Covers every chapter's grammar files, not just the core ones —
        # coarser than strictly necessary, but under-covering this set would
        # let a stale table survive a real grammar edit.
        def grammar_content_digest
          files = (MetaValidator::GRAMMAR_FILES + MetaValidator::WORLD_GRAMMAR + MetaValidator::HECKSAGON_GRAMMAR +
                    Dir.glob(File.join(MetaValidator::ATTACHED_GRAMMAR_DIR, "*.bluebook"))).sort
          Digest::SHA256.hexdigest(files.map { |file| File.read(file) }.join("\0"))
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

        # `to: "Syntax"` appends onto the record `declare_syntax` already
        # opened; putting the receiver in the payload instead would make
        # `Syntax.Keyword` look like a fresh identity to mint, colliding
        # with that row.
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

        # Same `to: "Syntax"` append shape `admit_keywords` uses, one type over.
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
