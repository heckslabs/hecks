require_relative "era_guard/shape_diff"
require_relative "../bluebook/dsl/malformed"
require_relative "../bluebook/meta_validator"
require_relative "../ports/loading"
require_relative "registry"

module Hecks
  module Runtime
    # The shape-drift coverage primitives — ADR 0032. Not a driver: nothing
    # here walks a registry or reads/writes a held snapshot on its own.
    # `PostgresEra::LineageManager::CoverageCheck` calls `uncovered_
    # attributes`/`unsafe_additions`/`refuse_uncovered!`/`refuse_unsafe_
    # addition!`/`check_vanished_aggregates!` directly, per translation
    # edge, over its own DB-held shapes; `Translation::Reattest` and
    # `PostgresEra::LineageManager` call `shadow_parse` directly, to read
    # historical bluebook text under old grammar defaults. Both are real,
    # independent, currently-shipped consumers.
    #
    # A prior version of this module ALSO drove its own top-level check —
    # `check!`/`check_bluebook!`, walking a registry and reading/writing a
    # held snapshot under `data/eras/*.bluebook` — duplicating, on its own,
    # the same per-aggregate walk `CoverageCheck` already performs against
    # `PostgresEra`'s own DB-held shapes. Nothing in production ever called
    # it (only a direct unit spec did); deleted rather than kept unwired,
    # per ADR 0032. Wanted again, it's rebuilt informed by `CoverageCheck`'s
    # real orchestration, not resurrected from here.
    module EraGuard
      extend ShapeDiff

      module_function

      # An aggregate that existed in the held text and answers to no
      # current name — renamed silently, with nothing declaring `was:` to
      # explain where its data went — is exactly the disease this guards
      # against, and a plain per-aggregate diff would never see it: the
      # current aggregate simply has no held counterpart to compare to.
      def check_vanished_aggregates!(registry, bluebook, held_bluebook)
        held_bluebook.aggregates.each do |held_aggregate|
          claimed = bluebook.aggregates.any? do |aggregate|
            aggregate.name == held_aggregate.name ||
              registry.translations.any? do |translation|
                translation.domain == bluebook.name &&
                  translation.for_aggregate(aggregate.name)&.was == held_aggregate.name
              end
          end
          claimed ||= registry.translations.any? do |translation|
            translation.domain == bluebook.name && translation.retired.include?(held_aggregate.name)
          end
          next if claimed

          raise WiringError,
                "cannot boot #{bluebook.name}: #{held_aggregate.name} existed and now doesn't, " \
                "and nothing declares was: #{held_aggregate.name.inspect} to explain where its data went."
        end
      end

      # The Layer-1 coverage refusal — one wording, shared with whoever
      # calls it (today, `PostgresEra::LineageManager::CoverageCheck`'s
      # own mint-time coverage check).
      def refuse_uncovered!(bluebook, aggregate, uncovered)
        raise WiringError,
              "cannot boot #{bluebook.name}::#{aggregate.name}: its shape changed and " \
              "#{uncovered.map { |path| render_path(path) }.join(', ')} #{uncovered.size == 1 ? 'is' : 'are'} not " \
              "explained by any rename, move, convert, retype, or drop. Update bluebook/translations/*.bluebook, e.g. " \
              "#{suggestion(uncovered.first)}."
      end

      # The addition-side sibling of refuse_uncovered! above — same
      # wording shape, different cause: nothing vanished or changed type,
      # something new arrived that an existing record has no way to hold.
      def refuse_unsafe_addition!(bluebook, aggregate, unsafe)
        raise WiringError,
              "cannot boot #{bluebook.name}::#{aggregate.name}: #{unsafe.map { |name| ":#{name}" }.join(', ')} " \
              "#{unsafe.size == 1 ? 'is new and required' : 'are new and required'}, with no default: to fill " \
              "an existing record and no translation explaining what one should read there. Give it a " \
              "default:, make it optional: true or list_of, or declare bluebook/translations/*.bluebook, e.g. " \
              "`backfill :#{unsafe.first}, default: ...`."
      end

      def render_path(path) = path.include?(".") ? path.inspect : ":#{path}"

      def suggestion(path)
        if path.include?(".")
          "`move #{path.inspect}, to: #{path.inspect}` or `drop #{path.inspect}`"
        else
          "`rename :#{path}, to: :new_name` or `drop :#{path}`"
        end
      end

      # Parses held source into its own IR, in a scratch registry so a past
      # era's text never touches the one actually booting.
      #
      # NORMAL PARSE FIRST, shadow only as a FALLBACK — not shadow-parsing
      # unconditionally, which is what this used to do. A handful of DSL
      # defaults fork on `MetaValidator.shadow_parsing?` for a reason
      # that has NOTHING to do with syntax the live grammar can no longer
      # read at all (`identified_by { }`, `belongs_to`, `has_one`,
      # `has_many` — genuinely removed spellings, exactly what shadow-
      # parsing exists to keep readable): `reference_to`'s own default
      # mint name (`default_reference_name`, attribute_collector.rb)
      # changed from `_id`-suffixed to bare under ADR 0025, and THAT fork
      # applies even to text using nothing but current, live syntax.
      # Held text minted under the CURRENT grammar — every real era in
      # this corpus today, since nothing has ever minted a second one —
      # parses fine normally; only the reference-naming DEFAULT differed
      # once shadow mode engaged unconditionally, so it silently
      # reconstructed a DIFFERENT shape (and hash) than a fresh parse of
      # the identical text — the same text hashing two different ways
      # depending on which code path read it, breaking `ensure_named!`'s
      # own from/to edge lookup with a spurious "no translation edge
      # covers it" refusal that has nothing to do with any real
      # translation gap.
      #
      # A normal parse can only ever SUCCEED on text the live grammar
      # fully understands — there is no way for it to silently produce a
      # wrong-but-plausible answer for genuinely legacy text, since every
      # removed spelling refuses loudly (`Malformed`) rather than
      # degrading. So: try normal first — if the ordinary grammar reads
      # this text without complaint, that IS the canonical, unambiguous
      # interpretation, the same one `label_of`/`mint_hash` on the same
      # source text always computes, whoever's asking. Only on a
      # `Malformed` refusal — the one signal that actually means "this
      # spelling doesn't exist anymore" — fall back to the legacy
      # grammar, exactly as before this change. Any OTHER exception (a
      # genuine syntax error, an unrelated validation refusal) propagates
      # unchanged; swallowing it here to retry under shadow mode would
      # risk masking a real defect in the held text behind a confusing
      # second failure instead of the original, more specific one.
      #
      # `MetaValidator.while_shadow_parsing` (ADR 0025, docs/dsl-work-
      # slices.md's S0a) is what makes the fallback a LEGACY grammar
      # rather than just a second copy of today's: it stops
      # `BluebookBuilder.build` from judging this text against the
      # grammar as it stands NOW, which is the one thing that would make
      # a removed spelling refuse HISTORY the day it is removed from
      # live source. The scratch registry is throwaway either way —
      # nothing here is dispatched against or exposed to the real one —
      # so skipping the judge/assemble round-trip changes nothing this
      # method reads: `shape`, `uncovered_attributes`, and friends only
      # ever ask the built IR for its own structure.
      def shadow_parse(source, path)
        parse_bluebook(source, path, shadow: false)
      rescue Hecks::Bluebook::DSL::Malformed
        parse_bluebook(source, path, shadow: true)
      end

      def parse_bluebook(source, path, shadow:)
        scratch = Registry.new
        loading = Ports::Loading.bootstrap
        run = lambda do
          Hecks.with_registry(scratch) do
            loading.load_library
            Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
          end
        end
        shadow ? Hecks::Bluebook::MetaValidator.while_shadow_parsing(&run) : run.call
        scratch.bluebooks.values.first
      end
    end
  end
end
