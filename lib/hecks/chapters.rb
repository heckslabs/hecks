require_relative "naming"
require_relative "framework"
require_relative "runtime/registry"
require_relative "bluebook/meta_validator"
require_relative "sentence_form"

module Hecks
  # The bluebooks the gem carries that a hecksagon can attach by name (ADR 0080): the language
  # declared in itself, Expression, Tenancy, Deploy, Site, Tickets, Composer, QualityControl,
  # Bulk and CiPipeline.
  # Framework members stay in `Framework`; `table` and `attach!` find a name across both.
  #
  # A bluebook is named by the `Hecks.bluebook "Name"` header of its files, and may span several.
  # Beside its bluebook a bluebook may carry what every hecksagon attaching it needs, whatever
  # its store: `<snake_name>.ports.hecksagon` (the ports it declares, as a `Hecks.hecksagon`
  # block that merges into the attaching one) and `adapters/*.adapter` (the adapters binding them).
  module Chapters
    # Where attachable bluebooks live, relative to `lib/hecks/`.
    GLOBS = %w[language/**/*.bluebook grammar/expression.bluebook tenancy/bluebook/*.bluebook
               deploy/bluebook/*.bluebook site/bluebook/*.bluebook rails_app/bluebook/*.bluebook tickets/bluebook/*.bluebook
               composer/bluebook/*.bluebook quality_control/*.bluebook bulk/bluebook/*.bluebook
               ci_pipeline/*.bluebook].freeze

    # A `Hecks.bluebook "Name"` header line, capturing the bluebook's name.
    BLUEBOOK_HEADER = /\A\s*Hecks\.bluebook\s+"([^"]+)"/

    # Every attachable bluebook, by name, with the files that declare it.
    #
    # @return [Hash{String => Array<String>}] bluebook name to its files' absolute paths, sorted
    def self.index
      @index ||= chapter_files.group_by { |path| chapter_name(path) }
                              .reject { |name, _| name.nil? }
                              .freeze
    end

    # @return [Array<String>] every file the globs find, sorted
    def self.chapter_files
      GLOBS.flat_map { |glob| Dir.glob(File.join(__dir__, glob)) }.sort
    end

    # Every bluebook the gem carries, whichever module loads it: the one lookup table `attaches`
    # finds a name in.
    #
    # @return [Hash{String => Array<String>}] bluebook name to its files' absolute paths, the
    #   framework members (`Framework.members`) and the attachable bluebooks (`index`) together
    def self.table
      Framework.members.transform_values { |path| [path] }.merge(index)
    end

    # Loads one gem bluebook by name, found in `table`: a framework member through
    # `Framework.load!`, any other bluebook through `load!`.
    #
    # @param name [String, Symbol] the bluebook's name, such as `"Governance"` or `"Deploy"`
    # @return [Boolean, nil] true when this call loaded it, nil when it was already held
    # @raise [Runtime::WiringError] if the gem carries no bluebook of that name; the message
    #   lists the known names and says how to attach a vendored package
    def self.attach!(name)
      key = name.to_s
      return Framework.load!(key) if Framework.members.key?(key)
      return load!(key) if index.key?(key)

      raise Runtime::WiringError,
            "attaches #{name.inspect}: the gem carries no chapter of that name — known: " \
            "#{table.keys.sort.join(", ")}. To attach a vendored package, write " \
            "`attaches #{name.to_s.inspect}, from: :vendor`"
    end

    # Loads a bluebook's files into the current registry, unless it already holds the bluebook.
    #
    # The files load together inside `MetaValidator.defer`, so a bluebook spread over several files
    # is judged once, whole. The bluebook's ports file and adapters load after it, since a port
    # names the bluebook's aggregates.
    #
    # @param name [String] the bluebook's name, such as `"Deploy"`
    # @return [Boolean, nil] true when this call loaded the bluebook, nil when it was already held
    # @raise [Runtime::WiringError] if no attachable bluebook has that name
    def self.load!(name)
      paths = chapter_paths(name)
      registry = open_registry(name)
      return refuse_own_chapter(registry, name.to_s) if registry.bluebook(name.to_s)

      load_atomically(registry, name.to_s, paths)
      true
    end

    # @return [Array<String>] the files of the named bluebook
    # @raise [Runtime::WiringError] if no attachable bluebook has that name
    def self.chapter_paths(name)
      index.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no attachable chapter named #{name.inspect} — known: #{index.keys.join(", ")}"
      end
    end

    # @return [Runtime::Registry] the registry the current boot is loading into
    # @raise [Runtime::WiringError] when no boot is open
    def self.open_registry(name)
      Hecks.current_registry or
        raise Runtime::WiringError, "attaches #{name.to_s.inspect} outside a boot: no registry is open"
    end

    # Loads a bluebook whole or not at all: a raise anywhere leaves the registry as it was, so a
    # retry loads the bluebook again instead of finding a half-built one already held.
    def self.load_atomically(registry, name, paths)
      before = { queued: Bluebook::MetaValidator.deferred_chapters.dup, ports: registry.ports.keys,
                 adapters: registry.adapters.keys }
      Bluebook::MetaValidator.defer { paths.each { |path| SentenceForm.load_file(path) } }
      Bluebook::MetaValidator.judge_deferred!(registry)
      load_wiring(name, paths)
    rescue Exception # rubocop:disable Lint/RescueException -- rolls back, then re-raises
      roll_back(registry, name, before)
      raise
    end

    # Puts the registry back as `load_atomically` found it.
    def self.roll_back(registry, name, before)
      registry.forget_chapter(name)
      Bluebook::MetaValidator.deferred_chapters.replace(before[:queued])
      registry.ports.delete_if { |key, _| !before[:ports].include?(key) }
      registry.adapters.delete_if { |key, _| !before[:adapters].include?(key) }
    end
    private_class_method :chapter_files, :chapter_paths, :open_registry, :load_atomically, :roll_back

    # Returns nil for a bluebook this gem already loaded; raises for a bluebook of the same name
    # that a user's own file declared, which `attaches` would otherwise silently take for the
    # gem's.
    def self.refuse_own_chapter(registry, name)
      foreign = Array(registry.bluebook_sources[name]).compact
                                                      .reject { |path| File.expand_path(path).start_with?("#{__dir__}/") }
      return if foreign.empty?

      raise Runtime::WiringError,
            "attaches #{name.inspect}, but a chapter named #{name.inspect} is already declared in " \
            "#{foreign.join(", ")} — rename it, since the gem's own #{name} chapter cannot merge into it"
    end
    private_class_method :refuse_own_chapter

    # Loads what a bluebook ships beside its bluebook: its ports file, then its adapters.
    #
    # @param name [String] the bluebook's name
    # @param paths [Array<String>] the bluebook's bluebook files
    # @return [void]
    def self.load_wiring(name, paths)
      directory = File.dirname(paths.first)
      ports     = File.join(directory, "#{Naming.snake(name)}.ports.hecksagon")
      Kernel.load(ports) if File.file?(ports)
      Dir.glob(File.join(directory, "adapters", "*.adapter")).each { |adapter| Kernel.load(adapter) }
    end
    private_class_method :load_wiring

    # The name a file's `Hecks.bluebook "Name"` header declares, or nil for a file without one.
    def self.chapter_name(path)
      File.foreach(path) { |line| return Regexp.last_match(1) if line =~ BLUEBOOK_HEADER }
      nil
    end
  end
end
