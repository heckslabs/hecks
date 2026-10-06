require_relative "bluebook/meta_validator"
require_relative "corpus"

module Hecks
  # Shared machinery for a codemod that migrates real `.bluebook` source: boot,
  # find candidates, edit, then verify by diffing the re-booted IR before keeping it.
  module Codemod
    ROOT = File.expand_path("../..", __dir__)

    EXAMPLE_ROOTS = Corpus.members(:example, root: ROOT).map(&:path)
    META_FILES    = (Dir.glob(File.join(ROOT, "lib/hecks/grammar/*.bluebook")) +
                      Dir.glob(File.join(ROOT, "lib/hecks/framework/bluebook/*.bluebook")) +
                      Dir.glob(File.join(ROOT, "lib/hecks/language/bluebook/**/*.bluebook"))).sort

    # Boots the lightweight, in-memory path — a codemod only reads a chapter's
    # own declared IR, never a stored record, so it has no reason to need Postgres.
    PERSISTENCE_PORT = File.join(ROOT, "lib/hecks/ports/persistence.port")
    EXTRACTION_PORT  = File.join(ROOT, "lib/hecks/ports/extraction.port")
    MEMORY_ADAPTER   = File.join(ROOT, "lib/hecks/adapters/driven/memory.adapter")
    PRISM_ADAPTER    = File.join(ROOT, "lib/hecks/adapters/driven/prism.adapter")

    def self.export_json(registry) = Hecks::Projector::Exporter.json(registry)

    # Text that stands in for a file while a dry run judges an edit.
    #
    # `Kernel.load` evaluates the staged text in place of the file, under the file's own path, so
    # a codemod can boot the edited bluebook without writing a tracked file: a dry run that is
    # interrupted, or read by a parallel process, leaves the checkout exactly as it was.
    module Shadow
      # Prepended to `Kernel`'s singleton: loads staged text when there is any for the file.
      module Loader
        # @param file [String] the path being loaded
        # @return [Boolean] true, as `Kernel.load` answers
        def load(file, *)
          text = Shadow.texts[file.to_s]
          return super unless text

          Hecks::Adapters::Prism::TREES[file.to_s] = ::Prism.parse(text).value
          eval(text, TOPLEVEL_BINDING.dup, file.to_s, 1)
          true
        end
      end
      Kernel.singleton_class.prepend(Loader)

      module_function

      # @return [Hash{String => String}] the staged text by absolute path
      def texts = (@texts ||= {})

      # Stages `text` as `file`'s contents and drops the file's cached parse.
      #
      # @param file [String] the path the text stands in for
      # @param text [String] the staged source
      # @return [String] the text
      def put(file, text)
        Hecks::Adapters::Prism.forget(file)
        texts[file] = text
      end

      # Stops standing in for `file`.
      #
      # @param file [String] the path to read from disk again
      # @return [void]
      def drop(file)
        texts.delete(file)
        Hecks::Adapters::Prism.forget(file)
      end

      # @return [Boolean] whether any text is staged
      def active? = !texts.empty?
    end

    # Puts `text` where `file`'s next load will find it: on disk, or (a dry run) staged in memory.
    #
    # @param file [String] the bluebook's path
    # @param text [String] the new source
    # @param dry_run [Boolean] whether to leave the file untouched
    # @return [void]
    def self.stage(file, text, dry_run:)
      dry_run ? Shadow.put(file, text) : File.write(file, text)
    end

    # Undoes `stage`: rewrites the original, or stops staging.
    #
    # @param file [String] the bluebook's path
    # @param original [String] the source as it was on disk
    # @param dry_run [Boolean] whether the edit was only staged
    # @return [void]
    def self.unstage(file, original, dry_run:)
      dry_run ? Shadow.drop(file) : File.write(file, original)
    end

    # Forgets each path's cached AST first — a stale tree after editing a file
    # misreports that file's own source locations.
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

    # Forgets every tree, not just one — callers rarely know which of the
    # meta-domain's several files they just edited.
    def self.boot_meta
      Hecks::Adapters::Prism.forget_all
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      export_json(Hecks::Bluebook::MetaValidator.grammar_registry)
    end

    def self.meta_registry
      Hecks::Adapters::Prism.forget_all
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      Hecks::Bluebook::MetaValidator.grammar_registry
    end

    # Walks nested entities recursively too, not just each aggregate's own commands.
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

    # Raises on a name collision between a value object and an entity — nothing
    # in the DSL prevents two from sharing a `hecks_name`, so it can't be resolved silently.
    def self.element_construct_for(construct, list_field)
      list_attr = owner_attribute(construct, list_field)
      return nil unless list_attr&.list?

      value_objects = construct.respond_to?(:value_objects) ? construct.value_objects : []
      entities      = construct.respond_to?(:entities) ? construct.entities : []
      matches = (value_objects + entities).select { |c| c.hecks_name.to_s == list_attr.type.to_s }

      if matches.size > 1
        raise "#{construct.hecks_name}##{list_field} names #{list_attr.type}, held by both a value " \
              "object and an entity — ambiguous, cannot resolve which one the list holds"
      end

      matches.first
    end

    # Rescues StandardError only, so a genuine bug still raises rather than
    # silently counting as an unsafe candidate to revert.
    def self.safely
      [yield, nil]
    rescue StandardError => e
      [nil, "#{e.class}: #{e.message}"]
    end

    # Runs one codemod rule across every example domain and the meta-domain,
    # verifying each candidate edit via IR diff before keeping it.
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
        puts "== results (#{dry_run ? "DRY RUN — nothing written" : "applied"}) =="
        puts "clean (no candidates): #{results[:clean].join(", ")}" unless results[:clean].empty?
        results[:applied].each { |r| puts "APPLIED  #{r[:file]}: #{r[:candidates].join(", ")}" }
        results[:skipped].each { |r| puts "SKIPPED  #{r[:file]} (#{r[:reason]}): #{Array(r[:candidates]).join(", ")}" }
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

      # Kept as one method: the write/verify/revert sequence is a single unit,
      # and splitting it would scatter shared state for no readability gain.
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
            Codemod.stage(target_file, text, dry_run: dry_run)
            after_json, error = Codemod.safely do
              Codemod.export_json(Codemod.load_bluebook(bluebook_files))
            end

            if after_json == before_json && !dry_run
              applied_by_file[target_file] << candidate
            elsif after_json == before_json
              live[target_file] = original_text
              Codemod.unstage(target_file, original_text, dry_run: dry_run)
              Codemod.safely { Codemod.load_bluebook(bluebook_files) }
              applied_by_file[target_file] << candidate
            else
              live[target_file] = original_text
              Codemod.unstage(target_file, original_text, dry_run: dry_run)
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

      # Per-candidate, not batched — the meta-domain is one shared,
      # self-dispatching registry (S14), so a single unsafe candidate could
      # otherwise sink every other, genuinely safe one in the same run.
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
          Codemod::META_FILES.each { |f| Codemod.stage(f, live_meta[f], dry_run: dry_run) }

          # A dry run stages the text in memory and reboots from it, then drops it — so the next
          # candidate is judged against the true original state and no file is written.
          after_meta, error = Codemod.safely { Codemod.boot_meta }

          if after_meta == before_meta && !dry_run
            applied_by_file[target_file] << candidate
          elsif after_meta == before_meta # dry-run, safe — revert, but count as applied
            live_meta[target_file] = original_text
            Codemod::META_FILES.each { |f| Codemod.unstage(f, live_meta[f], dry_run: dry_run) }
            Codemod.safely { Codemod.boot_meta }
            applied_by_file[target_file] << candidate
          else
            live_meta[target_file] = original_text
            Codemod::META_FILES.each { |f| Codemod.unstage(f, live_meta[f], dry_run: dry_run) }
            Codemod.safely { Codemod.boot_meta } # resync memoized state to the reverted text
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
