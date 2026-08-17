require_relative "bluebook/meta_validator"

module Hecksagain
  # SHARED MACHINERY for a codemod that migrates real `.bluebook` source
  # once a DSL builder change makes some previously-required declaration
  # optional/redundant — pulled out of `bin/codemod_implicit_append_fields`
  # (the first one built), which needed three real, hard-won fixes before
  # it could be trusted: a process-lifetime AST cache with no
  # invalidation, a batch-revert granularity that let one unsafe
  # candidate sink every other safe one sharing its boot, and (in the
  # SPINE the codemod migrates FOR, not here) an append-at-end insertion
  # that only round-tripped correctly for whichever field happened to be
  # last. None of those are guessable in advance; they only surface by
  # actually running a real edit against real self-hosted code. This
  # module is that lesson, kept — the NEXT codemod plugs in two rule-
  # specific procs (`find_candidates`, `apply_candidate`) and inherits
  # the boot/safety-net machinery rather than rediscovering it.
  #
  # A CODEMOD IS NOT PATTERN-MATCHING ALONE. Deciding "is this line safe
  # to delete" means knowing what the RUNTIME would resolve it to — so
  # every codemod built on this module follows the same three steps:
  #   1. Boot the real domain (or the self-hosted meta-domain) and read
  #      its IR to find CANDIDATES — provided by the caller's own
  #      `find_candidates`, since the actual redundancy rule is specific
  #      to whichever spine change this migration serves.
  #   2. Locate and remove each candidate's own source text — the
  #      caller's own `apply_candidate`.
  #   3. Re-boot from the edited text and diff the full IR export
  #      against the pre-edit export. Byte-identical -> keep. Anything
  #      else (including a RAISED exception — the self-hosted
  #      meta-domain DISPATCHES itself into being, S14, so a bad edit
  #      can surface as a runtime refusal, not just a differing export)
  #      -> revert and report SKIPPED, never silently guessed past.
  #
  # DESIGN-TIME CHECKLIST for the SPINE change a future codemod migrates
  # corpus text for — both items below are real bugs THIS module's own
  # first use found, not hypothetical:
  #   - Does the resolved value get inserted into an ORDER-SENSITIVE
  #     list (the exported IR is array-order-sensitive throughout)? If
  #     so, the spine's own insertion must preserve the ORIGINAL
  #     position, not just append — an append-at-end insertion only
  #     round-trips correctly for a value that already happened to be
  #     last.
  #   - Does resolution depend on ANOTHER construct already being
  #     declared (the aggregate/entity a `sets`/`append:` field resolves
  #     against)? If a creator command can be declared BEFORE the
  #     construct it creates (real, live: `command "Handler"` before
  #     `entity "Handler"`, one file down), one-pass resolution
  #     genuinely cannot see it yet — not a codemod bug, a structural
  #     limit worth naming rather than working around.
  module Codemod
    ROOT = File.expand_path("../..", __dir__)

    EXAMPLE_ROOTS = Dir.glob(File.join(ROOT, "examples", "*")).select { |p| File.directory?(p) }.sort
    META_FILES    = (Dir.glob(File.join(ROOT, "lib/hecksagain/grammar/*.bluebook")) +
                      Dir.glob(File.join(ROOT, "lib/hecksagain/framework/bluebook/*.bluebook")) +
                      Dir.glob(File.join(ROOT, "lib/hecksagain/language/bluebook/**/*.bluebook"))).sort

    # THE SAME LIGHTWEIGHT PATH `spec/spec_helper.rb`'s own
    # `boot_in_memory` uses — `Hecksagain.with_registry` satisfies
    # `Hecks.bluebook`'s own `collect`'s "loaded outside a boot" check
    # without `Hecks.boot`'s full era-check/adapter-wiring path, which
    # needs a LIVE Postgres connection for `compliance` and would make
    # every codemod depend on a database it has no reason to touch — a
    # codemod only ever reads a chapter's own declared IR, never a
    # stored record.
    PERSISTENCE_PORT = File.join(ROOT, "lib/hecksagain/ports/persistence.port")
    EXTRACTION_PORT  = File.join(ROOT, "lib/hecksagain/ports/extraction.port")
    MEMORY_ADAPTER   = File.join(ROOT, "lib/hecksagain/adapters/driven/memory.adapter")
    PRISM_ADAPTER    = File.join(ROOT, "lib/hecksagain/adapters/driven/prism.adapter")

    def self.export_json(registry) = Hecksagain::Projector::Exporter.json(registry)

    # `Hecksagain::Adapters::Prism` caches a file's parsed AST for the
    # life of the PROCESS, keyed by path — fine for every existing
    # caller (a file loads once per process: one `bin/ir` run, one
    # rspec worker), but a codemod legitimately reloads the SAME path
    # after editing it, and a stale cached tree reports a
    # `given`/`ensures` block at its OLD line number, which no longer
    # matches the freshly re-executed file's own `block.source_location`
    # — surfacing as "did not survive extraction" on a perfectly valid
    # file. `Prism.forget` is the real invalidation API this module's
    # own first use motivated (found here, fixed at the source rather
    # than left as a private `TREES.clear` poke from outside).
    def self.load_bluebook(path)
      Hecksagain::Adapters::Prism.forget(path)

      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(PERSISTENCE_PORT)
        Kernel.load(EXTRACTION_PORT)
        Kernel.load(MEMORY_ADAPTER)
        Kernel.load(PRISM_ADAPTER)
        Kernel.load(path)
      end
      registry
    end

    # `forget_all`, not a single `forget` — the meta-domain is NINE
    # files (`MetaValidator::GRAMMAR_FILES`) merged into one registry,
    # and a caller here (the codemod runner) doesn't generally know in
    # advance which ONE it just edited.
    def self.boot_meta
      Hecksagain::Adapters::Prism.forget_all
      Hecksagain::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      export_json(Hecksagain::Bluebook::MetaValidator.grammar_registry)
    end

    def self.meta_registry
      Hecksagain::Adapters::Prism.forget_all
      Hecksagain::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      Hecksagain::Bluebook::MetaValidator.grammar_registry
    end

    # Walks every aggregate (and every nested entity, recursively)
    # across every chapter in a booted registry, yielding [owning
    # construct, command] pairs — `construct` is whichever
    # Aggregate/Entity actually OWNS the command, the same distinction
    # `AggregateBuilder#command` vs `EntityBuilder#command` already
    # draws. Generic enough for any rule that needs to walk real
    # commands, not specific to the attribute-redundancy rule.
    def self.each_command(registry)
      registry.bluebooks.each_value do |chapter|
        chapter.aggregates.each do |aggregate|
          walk = lambda do |construct|
            construct.commands.each { |command| yield construct, command }
            construct.entities.each(&walk) if construct.respond_to?(:entities)
          end
          walk.call(aggregate)
        end
      end
    end

    def self.owner_attribute(construct, name)
      construct.attributes.find { |attr| attr.name.to_s == name.to_s }
    end

    # A LIST attribute's own element construct — the value object or
    # entity `list_of(...)` names, resolved by `hecks_name` the same way
    # `AttributeCollector#resolve_identity_field!` already does. Shared
    # because "what does this list actually hold" is a question any
    # append-shaped rule needs answered, not just this one.
    def self.element_construct_for(construct, list_field)
      list_attr = owner_attribute(construct, list_field)
      return nil unless list_attr&.list?

      pool = construct.respond_to?(:value_objects) ? construct.value_objects.dup : []
      pool.concat(construct.entities) if construct.respond_to?(:entities)
      pool.find { |c| c.hecks_name.to_s == list_attr.type.to_s }
    end

    # Either a raised exception OR a differing export counts as unsafe
    # — see the module header on why the meta-domain specifically can
    # raise. Returns [value_or_nil, error_message_or_nil].
    def self.safely
      [yield, nil]
    rescue StandardError => e
      [nil, "#{e.class}: #{e.message}"]
    end

    # THE REUSABLE RUNNER — every real bug fix this module carries lives
    # here, not in a caller's own script. A caller supplies:
    #
    #   find_candidates: ->(registry) { [...] }
    #     Given a booted registry, return every CANDIDATE this rule
    #     could migrate. A candidate is whatever shape the caller wants
    #     — `apply_candidate` is the only other thing that reads it.
    #
    #   apply_candidate: ->(text, candidate) { [new_text, changed_bool] }
    #     Given one file's current text and one candidate, return the
    #     edited text and whether a match was actually found/removed —
    #     `false` (text unchanged) when the candidate doesn't apply to
    #     THIS file, which is how the meta-domain's multi-file search
    #     below finds the right one without the caller needing to know
    #     which file a candidate lives in ahead of time.
    #
    #   label: ->(candidate) { "..." }
    #     One-line description for the results report.
    class Runner
      def initialize(find_candidates:, apply_candidate:, label:)
        @find_candidates = find_candidates
        @apply_candidate = apply_candidate
        @label = label
      end

      def run(dry_run: false)
        results = { applied: [], skipped: [], clean: [] }
        run_example_domains(results, dry_run)
        run_meta_domain(results, dry_run)
        results
      end

      def report(results, dry_run:)
        puts "== results (#{dry_run ? 'DRY RUN — nothing written' : 'applied'}) =="
        puts "clean (no candidates): #{results[:clean].join(', ')}" unless results[:clean].empty?
        results[:applied].each { |r| puts "APPLIED  #{r[:file]}: #{r[:candidates].join(', ')}" }
        results[:skipped].each { |r| puts "SKIPPED  #{r[:file]} (#{r[:reason]}): #{Array(r[:candidates]).join(', ')}" }
      end

      private

      def apply_many(text, candidates)
        applied = []
        candidates.each do |c|
          text, changed = @apply_candidate.call(text, c)
          applied << c if changed
        end
        [text, applied]
      end

      def run_example_domains(results, dry_run)
        Codemod::EXAMPLE_ROOTS.each do |domain_dir|
          bluebook_files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
          next if bluebook_files.empty?

          file = bluebook_files.first # every example domain here is one file
          before_json = Codemod.export_json(Codemod.load_bluebook(file))
          candidates  = @find_candidates.call(Codemod.load_bluebook(file))

          if candidates.empty?
            results[:clean] << domain_dir
            next
          end

          original = File.read(file)
          text, applied = apply_many(original, candidates)

          if applied.empty?
            results[:skipped] << { file: file, reason: "candidates found but no matching source line",
candidates: candidates.map(&@label) }
            next
          end

          # DRY RUN STILL VERIFIES — it writes the edit, reboots, and
          # diffs the SAME way a real run does (the only safe way to
          # know whether a candidate WOULD apply cleanly); it just
          # always writes the original text back afterward instead of
          # leaving the edit in place.
          File.write(file, text)
          after_json, error = Codemod.safely { Codemod.export_json(Codemod.load_bluebook(file)) }
          File.write(file, original) if dry_run || after_json != before_json

          if after_json == before_json
            results[:applied] << { file: file, candidates: applied.map(&@label) }
          else
            reason = error ? "reboot raised after edit (#{error}) — reverted" : "IR changed after edit — reverted"
            results[:skipped] << { file: file, reason: reason, candidates: applied.map(&@label) }
          end
        end
      end

      # PER-CANDIDATE, not one batched write-then-verify — the
      # meta-domain is ONE shared registry (SyntaxBoot DISPATCHES it
      # into itself, S14), so a single unsafe candidate among many would
      # otherwise sink every OTHER, genuinely safe candidate in the same
      # run: this module's first real run found exactly that (25
      # candidates, one dispatch-time break, all 25 reverted as a batch
      # before this per-candidate loop existed). `before_meta` stays the
      # fixed reference throughout — a truly safe candidate never
      # changes the IR, so the running state's own export should always
      # still equal the pristine original after each kept edit, by
      # definition, no moving target needed.
      def run_meta_domain(results, dry_run)
        before_meta     = Codemod.boot_meta
        meta_candidates = @find_candidates.call(Codemod.meta_registry)

        if meta_candidates.empty?
          results[:clean] << "meta-domain"
          return
        end

        live_meta = Codemod::META_FILES.to_h { |f| [f, File.read(f)] }
        applied_by_file = Hash.new { |h, k| h[k] = [] }

        meta_candidates.each do |candidate|
          target_file = Codemod::META_FILES.find { |f| apply_many(live_meta[f], [candidate]).last.any? }
          unless target_file
            results[:skipped] << { file: "meta-domain", reason: "no matching source line", candidates: [@label.call(candidate)] }
            next
          end

          text, = apply_many(live_meta[target_file], [candidate])
          original_text = live_meta[target_file]
          live_meta[target_file] = text
          Codemod::META_FILES.each { |f| File.write(f, live_meta[f]) }

          # DRY RUN STILL VERIFIES — see run_example_domains' own
          # comment; the edit is always written and rebooted for real,
          # then always reverted afterward when dry-run (whether or not
          # it was safe) so the next candidate is judged against the
          # true original state, never an accumulated hypothetical.
          after_meta, error = Codemod.safely { Codemod.boot_meta }

          if after_meta == before_meta && !dry_run
            applied_by_file[target_file] << candidate
          elsif after_meta == before_meta # dry-run, safe — revert, but count as applied
            live_meta[target_file] = original_text
            File.write(target_file, original_text)
            Codemod.safely { Codemod.boot_meta }
            applied_by_file[target_file] << candidate
          else
            live_meta[target_file] = original_text
            File.write(target_file, original_text)
            Codemod.safely { Codemod.boot_meta } # restore cache/memoized state to the reverted text
            reason = error ? "reboot raised (#{error})" : "IR changed"
            results[:skipped] << { file: "meta-domain", reason: reason, candidates: [@label.call(candidate)] }
          end
        end

        applied_by_file.each do |file, candidates|
          results[:applied] << { file: file, candidates: candidates.map(&@label) }
        end
      end
    end
  end
end
