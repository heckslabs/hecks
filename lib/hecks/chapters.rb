require_relative "runtime/registry"
require_relative "bluebook/meta_validator"

module Hecks
  # The chapters the gem carries that a hecksagon can attach by name (ADR 0080): the language
  # declared in itself, Expression, Tenancy and Deploy. Framework members stay in `Framework`.
  #
  # A chapter is named by the `Hecks.bluebook "Name"` header of its files, and may span several.
  module Chapters
    # Where attachable chapters live, relative to `lib/hecks/`.
    GLOBS = %w[language/**/*.bluebook grammar/expression.bluebook tenancy/bluebook/*.bluebook
               deploy/bluebook/*.bluebook].freeze

    # Every attachable chapter, by name, with the files that declare it.
    #
    # @return [Hash{String => Array<String>}] chapter name to its files' absolute paths, sorted
    def self.index
      @index ||= GLOBS.flat_map { |glob| Dir.glob(File.join(__dir__, glob)) }.sort
                      .group_by { |path| chapter_name(path) }
                      .reject { |name, _| name.nil? }
                      .freeze
    end

    # Loads a chapter's files into the current registry, unless it already holds the chapter.
    #
    # The files load together inside `MetaValidator.defer`, so a chapter spread over several files
    # is judged once, whole.
    #
    # @param name [String] the chapter's name, such as `"Deploy"`
    # @return [Boolean, nil] true when this call loaded the chapter, nil when it was already held
    # @raise [Runtime::WiringError] if no attachable chapter has that name
    def self.load!(name)
      paths = index.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no attachable chapter named #{name.inspect} — known: #{index.keys.join(', ')}"
      end
      registry = Hecks.current_registry
      return if registry.bluebook(name.to_s)

      Bluebook::MetaValidator.defer { paths.each { |path| Kernel.load(path) } }
      Bluebook::MetaValidator.judge_deferred!(registry)
      true
    end

    # The name a file's `Hecks.bluebook "Name"` header declares, or nil for a file without one.
    def self.chapter_name(path)
      File.foreach(path) { |line| return Regexp.last_match(1) if line =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
      nil
    end
  end
end
