require_relative "bluebook/meta_validator"
require_relative "corpus"

module Hecks
  # Shared machinery for a codemod that migrates real `.bluebook` source.
  #
  # ## Why this module exists
  #
  # For migrating source once a DSL builder change turns a required
  # declaration into an optional, redundant one — pulled out of
  # `bin/codemod_implicit_append_fields` (the first one built), which
  # needed three real, hard-won fixes before it could be trusted: a
  # process-lifetime AST cache with no invalidation, a batch-revert
  # granularity that let one unsafe candidate sink every other safe one
  # sharing its boot, and (in the spine the codemod migrates for, not
  # here) an append-at-end insertion that only round-tripped correctly
  # for whichever field happened to be last. None of those are guessable
  # in advance; they only surface by actually running a real edit
  # against real self-hosted code. This module is that lesson, kept —
  # the next codemod plugs in two rule-specific procs (`find_candidates`,
  # `apply_candidate`) and inherits the boot/safety-net machinery rather
  # than rediscovering it.
  #
  # ## The three-step contract
  #
  # **A codemod is not pattern-matching alone**. Deciding "is this line safe
  # to delete" means knowing what the runtime would resolve it to — so
  # every codemod built on this module follows the same three steps:
  #   1. Boot the real domain (or the self-hosted meta-domain) and read
  #      its IR to find candidates — provided by the caller's own
  #      `find_candidates`, since the actual redundancy rule is specific
  #      to whichever spine change this migration serves.
  #   2. Locate and remove each candidate's own source text — the
  #      caller's own `apply_candidate`.
  #   3. Re-boot from the edited text and diff the full IR export
  #      against the pre-edit export. Byte-identical -> keep. Anything
  #      else (including a raised exception — the self-hosted
  #      meta-domain dispatches itself into being, S14, so a bad edit
  #      can surface as a runtime refusal, not just a differing export)
  #      -> revert and report skipped, never silently guessed past.
  #
  # ## Design-time checklist for a future codemod
  #
  # For the spine change a future codemod migrates corpus text for —
  # both items below are real bugs this module's own first use found,
  # not hypothetical:
  #   - Does the resolved value get inserted into an order-sensitive
  #     list (the exported IR is array-order-sensitive throughout)? If
  #     so, the spine's own insertion must preserve the original
  #     position, not just append — an append-at-end insertion only
  #     round-trips correctly for a value that already happened to be
  #     last.
  #   - Does resolution depend on another construct already being
  #     declared (the aggregate/entity a `sets`/`append:` field resolves
  #     against)? If a creator command can be declared before the
  #     construct it creates (real, live: `command "Handler"` before
  #     `entity "Handler"`, one file down), one-pass resolution
  #     genuinely cannot see it yet — not a codemod bug, a structural
  #     limit worth naming rather than working around.
  module Codemod
    ROOT = File.expand_path("../..", __dir__)

    EXAMPLE_ROOTS = Corpus.members(:example, root: ROOT).map(&:path)
    META_FILES    = (Dir.glob(File.join(ROOT, "lib/hecks/grammar/*.bluebook")) +
                      Dir.glob(File.join(ROOT, "lib/hecks/framework/bluebook/*.bluebook")) +
                      Dir.glob(File.join(ROOT, "lib/hecks/language/bluebook/**/*.bluebook"))).sort

    # The same lightweight path `spec/spec_helper.rb`'s own
    # `boot_in_memory` uses — `Hecks.with_registry` satisfies
    # `Hecks.bluebook`'s own `collect`'s "loaded outside a boot" check
    # without `Hecks.boot`'s full era-check/adapter-wiring path, which
    # needs a live Postgres connection for `compliance` and would make
    # every codemod depend on a database it has no reason to touch — a
    # codemod only ever reads a chapter's own declared IR, never a
    # stored record.
    PERSISTENCE_PORT = File.join(ROOT, "lib/hecks/ports/persistence.port")
    EXTRACTION_PORT  = File.join(ROOT, "lib/hecks/ports/extraction.port")
    MEMORY_ADAPTER   = File.join(ROOT, "lib/hecks/adapters/driven/memory.adapter")
    PRISM_ADAPTER    = File.join(ROOT, "lib/hecks/adapters/driven/prism.adapter")

    # Exports a booted registry's canonical IR as JSON, for a before/after diff.
    #
    # @param registry [Runtime::Registry] the booted registry to export
    # @return [String] the pretty-printed JSON IR export
    def self.export_json(registry) = Hecks::Projector::Exporter.json(registry)

    # `Hecks::Adapters::Prism` caches a file's parsed AST for the
    # life of the process, keyed by path — fine for every existing
    # caller (a file loads once per process: one `bin/ir` run, one
    # rspec worker), but a codemod legitimately reloads the same path
    # after editing it, and a stale cached tree reports a
    # `given`/`ensures` block at its old line number, which no longer
    # matches the freshly re-executed file's own `block.source_location`
    # — surfacing as "did not survive extraction" on a perfectly valid
    # file. `Prism.forget` is the real invalidation API this module's
    # own first use motivated (found here, fixed at the source rather
    # than left as a private `TREES.clear` poke from outside).
    #
    # @param path [String, Array<String>] a single `.bluebook` file, a directory
    #   to glob every `.bluebook` file from, or an explicit list of file paths
    # @return [Runtime::Registry] a fresh registry with every file loaded and judged
    def self.load_bluebook(path)
      paths = if path.is_a?(Array)
                path
              elsif File.directory?(path)
                Dir.glob(File.join(path, "*.bluebook"))
              else
                [path]
              end
      paths.each { |file| Hecks::Adapters::Prism.forget(file) }

      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(PERSISTENCE_PORT)
        Kernel.load(EXTRACTION_PORT)
        Kernel.load(MEMORY_ADAPTER)
        Kernel.load(PRISM_ADAPTER)
        Hecks::Bluebook::MetaValidator.defer { paths.each { |file| Kernel.load(file) } }
        Hecks::Bluebook::MetaValidator.judge_deferred!(registry)
      end
      registry
    end

    # `forget_all`, not a single `forget` — the meta-domain is nine
    # files (`MetaValidator::GRAMMAR_FILES`) merged into one registry,
    # and a caller here (the codemod runner) doesn't generally know in
    # advance which one it just edited.
    # @return [String] the freshly re-derived meta-domain's canonical IR, as JSON
    def self.boot_meta
      Hecks::Adapters::Prism.forget_all
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      export_json(Hecks::Bluebook::MetaValidator.grammar_registry)
    end

    # Forces the self-hosted meta-domain to re-derive from its current source,
    # discarding any cached parse trees or memoized registry.
    #
    # @return [Runtime::Registry] the freshly re-derived meta-domain's registry
    def self.meta_registry
      Hecks::Adapters::Prism.forget_all
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      Hecks::Bluebook::MetaValidator.grammar_registry
    end

    # Walks every aggregate (and every nested entity, recursively)
    # across every chapter in a booted registry, yielding [owning
    # construct, command] pairs — `construct` is whichever
    # Aggregate/Entity actually owns the command, the same distinction
    # `AggregateBuilder#command` vs `EntityBuilder#command` already
    # draws. Generic enough for any rule that needs to walk real
    # commands, not specific to the attribute-redundancy rule.
    #
    # @param registry [Runtime::Registry] a booted registry
    # @yield [construct, command] every command in the registry, once per aggregate
    #   and once per nested entity
    # @yieldparam construct [Bluebook::Aggregate, Bluebook::Entity] whichever
    #   aggregate or entity actually owns `command`
    # @yieldparam command [Bluebook::Command] the command
    # @return [Hash{String => Bluebook::Chapter}] `registry.bluebooks`, unchanged
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

    # Finds one construct's own attribute by name.
    #
    # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct to search
    # @param name [String, Symbol, #to_s] the attribute's declared name
    # @return [Bluebook::Attribute, nil] the matching attribute, or nil if `construct`
    #   declares no attribute named `name`
    def self.owner_attribute(construct, name)
      construct.attributes.find { |attr| attr.name.to_s == name.to_s }
    end

    # A list attribute's own element construct — the value object or
    # entity `list_of(...)` names, resolved by `hecks_name` the same way
    # `AttributeCollector#resolve_identity_field!` already does. Shared
    # because "what does this list actually hold" is a question any
    # append-shaped rule needs answered, not just this one.
    #
    # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct
    #   declaring `list_field`
    # @param list_field [String, Symbol, #to_s] the name of the `list_of(...)` attribute
    # @return [Bluebook::Entity, Bluebook::ValueObject, nil] the construct
    #   `list_field` holds a list of, or nil if `list_field` names no attribute,
    #   isn't a list, or names no known value object or entity
    def self.element_construct_for(construct, list_field)
      list_attr = owner_attribute(construct, list_field)
      return nil unless list_attr&.list?

      pool = construct.respond_to?(:value_objects) ? construct.value_objects.dup : []
      pool.concat(construct.entities) if construct.respond_to?(:entities)
      pool.find { |c| c.hecks_name.to_s == list_attr.type.to_s }
    end

    # Either a raised exception or a differing export counts as unsafe
    # — see the module header on why the meta-domain specifically can
    # raise. Returns [value_or_nil, error_message_or_nil].
    #
    # @yield the risky boot/export step to run
    # @return [Array(Object, nil), Array(nil, String)] `[the block's result, nil]`
    #   on success, or `[nil, "ExceptionClass: message"]` if the block raises
    #   any StandardError
    def self.safely
      [yield, nil]
    rescue StandardError => e
      [nil, "#{e.class}: #{e.message}"]
    end

    # **The reusable runner** — every real bug fix this module carries lives
    # here, not in a caller's own script. A caller supplies:
    #
    #   find_candidates: ->(registry) { [...] }
    #     Given a booted registry, return every candidate this rule
    #     could migrate. A candidate is whatever shape the caller wants
    #     — `apply_candidate` is the only other thing that reads it.
    #
    #   apply_candidate: ->(text, candidate) { [new_text, changed_bool] }
    #     Given one file's current text and one candidate, return the
    #     edited text and whether a match was actually found/removed —
    #     `false` (text unchanged) when the candidate doesn't apply to
    #     this file, which is how the meta-domain's multi-file search
    #     below finds the right one without the caller needing to know
    #     which file a candidate lives in ahead of time.
    #
    #   label: ->(candidate) { "..." }
    #     One-line description for the results report.
    class Runner
      # @param find_candidates [Proc] `->(registry) { [...] }` — given a booted
      #   registry, returns every candidate this rule could migrate; a candidate's
      #   shape is the caller's own, read back only by `apply_candidate`
      # @param apply_candidate [Proc] `->(text, candidate) { [new_text, changed_bool] }`
      #   — given one file's current text and one candidate, returns the edited text
      #   and whether a match was found; `false` means the candidate doesn't apply to
      #   this file
      # @param label [Proc] `->(candidate) { "..." }` — a one-line description of a
      #   candidate, for the results report
      def initialize(find_candidates:, apply_candidate:, label:)
        @find_candidates = find_candidates
        @apply_candidate = apply_candidate
        @label = label
      end

      # Runs this rule's codemod across every example domain and the meta-domain.
      #
      # @param dry_run [Boolean] when true, every safe edit is still written and
      #   reverified, then reverted rather than kept
      # @return [Hash{Symbol => Array}] `:applied` (`Array<Hash{file: String,
      #   candidates: Array<String>}>`), `:skipped` (`Array<Hash{file: String,
      #   reason: String, candidates: Array<String>}>`), and `:clean`
      #   (`Array<String>` of domain directories or `"meta-domain"` with no candidates)
      def run(dry_run: false)
        results = { applied: [], skipped: [], clean: [] }
        run_example_domains(results, dry_run)
        run_meta_domain(results, dry_run)
        results
      end

      # Prints `run`'s results to stdout.
      #
      # @param results [Hash{Symbol => Array}] a `run` result
      # @param dry_run [Boolean] whether this was a dry run, for the report's own heading
      # @return [void]
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

      # The per-candidate write/verify/revert sequence below is one
      # coherent unit (see the comment ahead of the candidates.each
      # loop for why it can't batch) — splitting it across methods just
      # to satisfy the line count would scatter state four ways for no
      # readability gain.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/BlockLength
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/MethodLength
      # rubocop:disable-next Metrics/PerceivedComplexity
      def run_example_domains(results, dry_run)
        Codemod::EXAMPLE_ROOTS.each do |domain_dir|
          bluebook_files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
          next if bluebook_files.empty?

          before_json = Codemod.export_json(Codemod.load_bluebook(bluebook_files))
          candidates  = @find_candidates.call(Codemod.load_bluebook(bluebook_files))

          if candidates.empty?
            results[:clean] << domain_dir
            next
          end

          live = bluebook_files.to_h { |file| [file, File.read(file)] }
          applied_by_file = Hash.new { |hash, file| hash[file] = [] }

          candidates.each do |candidate|
            target_file = bluebook_files.find { |file| apply_many(live[file], [candidate]).last.any? }
            unless target_file
              results[:skipped] << { file: domain_dir, reason: "no matching source line", candidates: [@label.call(candidate)] }
              next
            end

            original_text = live[target_file]
            text, = apply_many(original_text, [candidate])
            live[target_file] = text
            File.write(target_file, text)
            after_json, error = Codemod.safely do
              Codemod.export_json(Codemod.load_bluebook(bluebook_files))
            end

            if after_json == before_json && !dry_run
              applied_by_file[target_file] << candidate
            elsif after_json == before_json
              live[target_file] = original_text
              File.write(target_file, original_text)
              Codemod.safely { Codemod.load_bluebook(bluebook_files) }
              applied_by_file[target_file] << candidate
            else
              live[target_file] = original_text
              File.write(target_file, original_text)
              Codemod.safely { Codemod.load_bluebook(bluebook_files) }
              reason = error ? "reboot raised after edit (#{error}) — reverted" : "IR changed after edit — reverted"
              results[:skipped] << { file: target_file, reason: reason, candidates: [@label.call(candidate)] }
            end
          end

          applied_by_file.each do |file, applied|
            results[:applied] << { file: file, candidates: applied.map(&@label) }
          end
        end
      end

      # Per-candidate, not one batched write-then-verify — the
      # meta-domain is one shared registry (SyntaxBoot dispatches it
      # into itself, S14), so a single unsafe candidate among many would
      # otherwise sink every other, genuinely safe candidate in the same
      # run: this module's first real run found exactly that (25
      # candidates, one dispatch-time break, all 25 reverted as a batch
      # before this per-candidate loop existed). `before_meta` stays the
      # fixed reference throughout — a truly safe candidate never
      # changes the IR, so the running state's own export should always
      # still equal the pristine original after each kept edit, by
      # definition, no moving target needed.
      # Same shape and same reason as run_example_domains just above (see
      # its own comment) — the write/verify/revert sequence, per
      # candidate (this method's own comment explains why it cannot
      # batch), is one coherent unit; splitting it would scatter
      # before_meta/live_meta/applied_by_file state across methods for
      # no gain.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
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

          # **Dry run still verifies** — see run_example_domains' own
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
