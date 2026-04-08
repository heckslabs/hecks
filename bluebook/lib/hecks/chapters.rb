# Hecks::Chapters
#
# Infrastructure for self-describing chapter definitions.
# Provides paragraph loading, aggregate loading from chapters,
# and chapter-to-implementation wiring via naming conventions.
#
#   Chapters.require_paragraphs(__FILE__)
#   Chapters.load_aggregates(Targets::Go, base_dir: "go_hecks")
#   Chapters.load_chapter(Bluebook, base_dir: "bluebook/lib")
#
module Hecks
  module Chapters
    # Require all paragraph files in a chapter's subdirectory.
    #
    #   Chapters.require_paragraphs(__FILE__)
    #
    def self.require_paragraphs(chapter_file)
      paragraph_dir = chapter_file.sub(/\.rb$/, "")
      return unless File.directory?(paragraph_dir)
      Dir.glob(File.join(paragraph_dir, "*.rb")).sort.each { |f| require f }
    end

    # Require implementation files for a paragraph's aggregates.
    #
    #   Chapters.load_aggregates(Targets::Go, base_dir: "go_hecks")
    #
    def self.load_aggregates(paragraph_module, base_dir:)
      builder = Hecks::DSL::BluebookBuilder.new("tmp")
      paragraph_module.define(builder)
      require_aggregates(builder.build.aggregates, base_dir: base_dir)
    end

    # Load all aggregates from a chapter (inline + paragraphs).
    #
    #   Chapters.load_chapter(Bluebook, base_dir: "bluebook/lib")
    #
    def self.load_chapter(chapter_module, base_dir:)
      if chapter_module.respond_to?(:definition)
        require_aggregates(chapter_module.definition.aggregates, base_dir: base_dir)
      end
      chapter_module.constants.each do |const|
        mod = chapter_module.const_get(const)
        load_aggregates(mod, base_dir: base_dir) if mod.respond_to?(:define)
      end
    end

    # Call .define(builder) on each paragraph module in the chapter.
    #
    #   Chapters.define_paragraphs(Runtime, builder)
    #
    def self.define_paragraphs(chapter_module, builder)
      chapter_module.constants.each do |const|
        mod = chapter_module.const_get(const)
        mod.define(builder) if mod.respond_to?(:define)
      end
    end

    # Require files matching aggregate names from base_dir.
    # Indexes files by basename, filters child files loaded by parents,
    # and maps aggregate names via underscore convention.
    def self.require_aggregates(aggregates, base_dir:)
      base = File.expand_path(base_dir)
      all_files = Dir.glob(File.join(base, "**", "*.rb"))

      # Exclude child files (foo/bar.rb when foo.rb exists)
      # but only below the top level of base_dir
      parent_dirs = all_files
        .select { |f| f.sub("#{base}/", "").count("/") >= 1 }
        .map { |f| f.sub(/\.rb$/, "") }
        .select { |d| File.directory?(d) }
      child_prefixes = parent_dirs.map { |d| "#{d}/" }
      top_files = all_files
        .reject { |f| child_prefixes.any? { |p| f.start_with?(p) } }
        .sort_by { |f| [f.count("/"), f] }

      by_name = {}
      top_files.each { |f| by_name[File.basename(f, ".rb")] ||= f }

      aggregates.each do |agg|
        snake = underscore(agg.name)
        file = by_name[snake] || by_name[snake.sub(/\A[a-z]+_/, "")]
        require file if file
      end
    end
    private_class_method :require_aggregates

    def self.underscore(str)
      str.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .downcase
    end
    private_class_method :underscore
  end
end
