# Hecks::ChapterLoader
#
# Registry and selective loader for Bluebook chapters. Maps chapter
# names to require paths and setup blocks. Enables composable Hecks
# installations — load only the chapters your project needs.
#
#   Hecks.chapters :bluebook, :runtime           # in code
#   Hecks.chapters :all                          # everything
#
# Or via a HecksChapters file in the project root:
#
#   # HecksChapters
#   chapter :bluebook
#   chapter :runtime
#
module Hecks
  # Hecks::ChapterLoader
  #
  # Maps chapter symbols to require paths and load blocks for selective chapter loading.
  #
  module ChapterLoader
    Entry = Struct.new(:name, :requires, :load_block, keyword_init: true)

    @registry = {}
    @loaded = []
    @frozen = false

    class << self
      # Register a chapter with its require paths and optional load block.
      #
      # @param name [Symbol] chapter name
      # @param requires [Array<String>] files to require
      # @yield optional setup block run after requires
      def register(name, requires: [], &load_block)
        @registry[name] = Entry.new(name: name, requires: requires, load_block: load_block)
      end

      # Load specific chapters by name. Uses two-phase loading:
      # Phase 1 requires all files (so autoloads resolve), then
      # Phase 2 runs load blocks (which may call load_chapter).
      #
      # @param names [Array<Symbol>] chapter names, or [:all]
      def load_chapters(*names)
        targets = if names == [:all]
                    @registry.keys
                  else
                    names
                  end

        # Phase 1: require all chapter files
        targets.each { |name| require_one(name) }

        # Phase 2: run load blocks (aggregate wiring, etc.)
        targets.each { |name| run_block(name) }

        @frozen = true
      end

      # Load chapters from a HecksChapters file if one exists.
      # Searches the current working directory.
      #
      # @return [Boolean] true if a HecksChapters file was found and loaded
      def load_from_file(dir = Dir.pwd)
        path = File.join(dir, "HecksChapters")
        return false unless File.exist?(path)

        dsl = FileDSL.new
        dsl.instance_eval(File.read(path), path, 1)
        load_chapters(*dsl.chapter_names)
        true
      end

      # @return [Array<Symbol>] names of loaded chapters
      def loaded = @loaded.dup

      # @return [Array<Symbol>] all registered chapter names
      def available = @registry.keys

      # @return [Boolean] whether chapters have been loaded
      def frozen? = @frozen

      private

      def require_one(name)
        return if @loaded.include?(name)

        entry = @registry[name]
        raise ArgumentError, "Unknown chapter: #{name}. Available: #{available.join(', ')}" unless entry

        entry.requires.each { |r| require r }
      end

      def run_block(name)
        return if @loaded.include?(name)

        entry = @registry[name]
        return unless entry

        entry.load_block&.call
        @loaded << name
      end
    end

    # Hecks::ChapterLoader::FileDSL
    #
    # Minimal DSL for parsing HecksChapters files.
    #
    class FileDSL
      attr_reader :chapter_names

      def initialize
        @chapter_names = []
      end

      def chapter(name)
        @chapter_names << name.to_sym
      end
    end
  end

  # DSL method for selecting chapters.
  #
  #   Hecks.chapters :bluebook, :runtime
  #   Hecks.chapters :all
  #
  def self.chapters(*names)
    ChapterLoader.load_chapters(*names)
  end
end
