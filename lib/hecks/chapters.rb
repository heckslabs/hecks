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

    # Load implementation files for a chapter from its base directories.
    # Discovers aggregate names by scanning the .bluebook source file
    # with a lightweight regex -- avoids calling .definition which would
    # trigger the full DSL before Grammar infrastructure is ready.
    #
    #   Chapters.load_chapter(Bluebook, base_dir: "bluebook/lib")
    #   Chapters.load_chapter(Bluebook, base_dirs: ["lib/hecks/domain", "lib/hecks/dsl"])
    #
    def self.load_chapter(chapter_module, base_dir: nil, base_dirs: nil)
      dirs = base_dirs || [base_dir]
      names = aggregate_names_from_bluebook(chapter_module)
      if names
        agg_structs = names.map { |n| OpenStruct.new(name: n) }
        dirs.each { |d| require_aggregates(agg_structs, base_dir: d) }
      end
      chapter_module.constants.each do |const|
        mod = chapter_module.const_get(const)
        next unless mod.respond_to?(:define)
        dirs.each { |d| load_aggregates(mod, base_dir: d) }
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

    # Load a chapter definition from a .bluebook file in the hecks/ directory.
    # Replaces paragraph-based definitions with pure bluebook source.
    #
    #   Chapters.definition_from_bluebook("runtime")
    #
    BLUEBOOK_DIR = File.expand_path("../../../hecks", __FILE__)

    def self.definition_from_bluebook(name)
      path = File.join(BLUEBOOK_DIR, "#{name}.bluebook")
      return nil unless File.exist?(path)

      source = File.read(path)
      # Extract domain name and block body from the Hecks.bluebook header
      header = /\AHecks\.bluebook\s+"([^"]+)"[^\n]*\s+do\s*\n/
      domain_name = source[header, 1] || name.capitalize
      body = source.sub(header, "").sub(/\nend\s*\z/, "")

      DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
        builder = DSL::BluebookBuilder.new(domain_name)
        builder.instance_eval(body, path, 2)
        domain = builder.build
        domain.source_path = path
        Hecks.last_domain = domain if Hecks.respond_to?(:last_domain=)
        domain
      end
    end

    # Extract aggregate names from a chapter's .bluebook file using a
    # lightweight regex scan. Returns nil if no .bluebook file exists.
    # This avoids triggering the full DSL / Grammar infrastructure.
    def self.aggregate_names_from_bluebook(chapter_module)
      slug = chapter_module.name.to_s.split("::").last
      return nil unless slug
      path = File.join(BLUEBOOK_DIR, "#{underscore(slug)}.bluebook")
      return nil unless File.exist?(path)
      File.read(path).scan(/^\s*aggregate\s+"([^"]+)"/).flatten
    end
    private_class_method :aggregate_names_from_bluebook

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

  # Flatten the Chapters namespace: Hecks::Bluebook resolves to
  # Hecks::Bluebook when no direct constant exists.
  def self.const_missing(name)
    if Chapters.const_defined?(name, false)
      Chapters.const_get(name)
    else
      super
    end
  end
end
