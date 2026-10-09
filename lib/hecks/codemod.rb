require_relative "bluebook/meta_validator"
require_relative "corpus"
require_relative "codemod/runner"

module Hecks
  # Shared machinery for a codemod that migrates real `.bluebook` source: boot,
  # find candidates, edit, then verify by diffing the re-booted IR before keeping it.
  module Codemod
    # Raised when a shadow cannot be built from the construct.
    class Error < RuntimeError; end

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
    BOOT_FILES       = [PERSISTENCE_PORT, EXTRACTION_PORT, MEMORY_ADAPTER, PRISM_ADAPTER].freeze

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
      paths = bluebook_paths(path)
      paths.each { |file| Hecks::Adapters::Prism.forget(file) }

      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        BOOT_FILES.each { |file| Kernel.load(file) }
        Hecks::Bluebook::MetaValidator.defer { paths.each { |file| Kernel.load(file) } }
        Hecks::Bluebook::MetaValidator.judge_deferred!(registry)
      end
      registry
    end

    # @param path [String, Array<String>] a bluebook file, a directory of them, or a list of files
    # @return [Array<String>] the bluebook files it names
    def self.bluebook_paths(path)
      return path if path.is_a?(Array)

      File.directory?(path) ? Dir.glob(File.join(path, "*.bluebook")) : [path]
    end
    private_class_method :bluebook_paths

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

      matches = element_candidates(construct).select { |c| c.hecks_name.to_s == list_attr.type.to_s }
      if matches.size > 1
        raise Error, "#{construct.hecks_name}##{list_field} names #{list_attr.type}, held by both a value " \
                     "object and an entity — ambiguous, cannot resolve which one the list holds"
      end

      matches.first
    end

    # @return [Array<Object>] the construct's value objects and entities, whichever it has
    def self.element_candidates(construct)
      value_objects = construct.respond_to?(:value_objects) ? construct.value_objects : []
      entities      = construct.respond_to?(:entities) ? construct.entities : []
      value_objects + entities
    end
    private_class_method :element_candidates

    # Rescues StandardError only, so a genuine bug still raises rather than
    # silently counting as an unsafe candidate to revert.
    def self.safely
      [yield, nil]
    rescue StandardError => e
      [nil, "#{e.class}: #{e.message}"]
    end
  end
end
