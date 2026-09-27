require_relative "../../hecks"
require_relative "../bluebook/model_check"

module Hecks
  module CLI
    # The command behind `bin/model_check` and `hecks model_check`: static analysis
    # over the IR, printed per domain, exiting non-zero when any error-severity
    # finding is left.
    #
    # It finds unreachable lifecycle states, transitions nothing can fire, saga
    # states no handler chain reaches, a compensation whose `from_state` is
    # unreachable, dispatches to a command that does not exist, and handlers
    # listening for an event nothing emits. The runtime checks none of these: a dead
    # transition never fires, in silence.
    #
    # ## Named domains, or the whole corpus
    #
    # Given domain paths, it boots each and runs one cross-domain check across all
    # of them. Given none, it sweeps the repository's corpus (`Corpus.model_check_members`)
    # and the language's own chapters; that needs `root:`, the repository, so an
    # installed gem without one asks for a domain path instead.
    #
    # ## Options
    #
    # `--strict` makes a `rust_reserved_name` finding an error for every target, not
    # only for those with a Cargo feature under `root`'s `rust/Cargo.toml`.
    # `--profile client` adds `Bluebook::ModelCheck::ClientProfile`'s error findings.
    module ModelCheck
      # The directory the framework's own `.port` and `.adapter` files live under.
      HECKS_DIR = File.expand_path("..", __dir__)

      # How one run is configured: `strict` and `profile` from the command line,
      # `rust_dir` from the root (nil without one).
      Options = Struct.new(:strict, :profile, :rust_dir)

      module_function

      # Runs the model check `argv` describes and exits with its verdict.
      #
      # @param argv [Array<String>] `--strict`, `--profile NAME` and domain paths
      # @param program [String] the name the usage message calls this command by
      # @param root [String, nil] the repository root, for the corpus sweep and the
      #   Rust-target check; nil when there is no checkout
      # @return [void]
      # @raise [SystemExit] always: 0 when clean, 1 with findings or a usage error,
      #   2 for an unknown profile
      def call(argv, program:, root: nil)
        argv = argv.dup
        strict = !argv.delete("--strict").nil?
        profile = take_profile(argv)
        unless profile.nil? || Bluebook::ModelCheck::PROFILES.include?(profile)
          warn "unknown profile #{profile.inspect} (known: #{Bluebook::ModelCheck::PROFILES.join(', ')})"
          exit 2
        end

        options = Options.new(strict, profile, root && File.join(root, "rust"))
        ok = if argv.any? then check_domains(argv, options)
             elsif root then check_corpus(root, options)
             else abort "usage: #{program} [--strict] [--profile client] <domain> [<domain> …]"
             end

        puts
        puts ok ? "No dead states, no unreachable protocol steps." : "THE MODEL HAS FINDINGS."
        exit(ok ? 0 : 1)
      end

      # Reads `--profile client` or `--profile=client` and removes it from `argv`.
      #
      # @param argv [Array<String>] the arguments, changed in place
      # @return [Symbol, nil] the requested profile, or nil when none was asked for
      def take_profile(argv)
        inline = argv.find { |arg| arg.start_with?("--profile=") }
        index = argv.index("--profile")
        return unless inline || index

        name = inline ? inline.delete_prefix("--profile=") : argv[index + 1].to_s
        argv.delete(inline) if inline
        argv.slice!(index, 2) if index
        name.to_sym
      end

      # Boots each named domain and examines them against one shared set of known
      # domains and emitted events, so a cross-domain reaction between two of them
      # is checked.
      #
      # @param domain_args [Array<String>] domain directory paths
      # @param options [Options] the run's configuration
      # @return [Boolean] true when every domain passes
      def check_domains(domain_args, options)
        booted = domain_args.map do |domain_arg|
          [File.basename(domain_arg.chomp("/")), boot(bluebook_dir(domain_arg.chomp("/")) || domain_arg, options)]
        end
        examine_all(booted, options)
      end

      # Boots every corpus member once, then examines each against the set of names
      # every member declares, then examines the language itself.
      #
      # Two passes over the same boots, because a single boot's own registry cannot
      # answer whether a target domain exists anywhere in the corpus.
      #
      # @param root [String] the repository root
      # @param options [Options] the run's configuration
      # @return [Boolean] true when every member and the language pass
      def check_corpus(root, options)
        require_relative "../corpus"
        targets = Corpus.model_check_members(root: root).map { |member| [member.stem, Corpus.source_of(member)] }
        booted = targets.map { |name, source| [name, boot(source, options)] }
        ok = examine_all(booted, options)
        examine_language(options) && ok
      end

      # Boots one source into a fresh registry, with its sibling hecksagons so a
      # policy bound from there is visible too.
      #
      # `root:` is the source's parent: a directory source is already the domain's
      # own `bluebook/` folder, and without a root a member declaring
      # `uses_embryonaut_bluebook` refuses with "needs a registry with a root to
      # vendor from".
      #
      # @param source [String] a directory to boot (every bluebook within), or a
      #   single `.bluebook` file path
      # @param options [Options] the run's configuration
      # @return [Runtime::Registry] the registry populated with the booted bluebooks
      def boot(source, options)
        root = File.directory?(source) ? File.dirname(source) : nil
        registry = Runtime::Registry.new(root: root)
        Hecks.with_registry(registry) { load_source(source, options) }
        registry
      end

      # @api private
      def load_source(source, options)
        Kernel.load(File.join(HECKS_DIR, "ports/persistence.port"))
        Kernel.load(File.join(HECKS_DIR, "ports/extraction.port"))
        Kernel.load(File.join(HECKS_DIR, "adapters/driven/memory.adapter"))
        Kernel.load(File.join(HECKS_DIR, "adapters/driven/prism.adapter"))
        folder = Adapters::Folder.new
        if File.directory?(source)
          folder.load_bluebooks(source)
        else
          folder.load_bluebooks(File.dirname(source), [File.basename(source)])
        end

        # Translations load only under a profile: the client profile's compute rule
        # reads them, and an unprofiled run boots exactly the chapters.
        if options.profile && File.directory?(source)
          Dir[File.join(source, "translations", "*.bluebook")].each { |file| Kernel.load(file) }
        end

        # A port attaches to its aggregate from the hecksagon, not the bluebook, so a
        # deaf-policy check that never loads it would see a policy reacting to an
        # event nothing appears to emit. A directory loads every `*.hecksagon` in it,
        # as a real boot does. Recording a bind builds IR only, so no adapter needs to
        # resolve here.
        hecksagons = if File.directory?(source)
                       Dir.glob(File.join(source, "*.hecksagon"))
                     else
                       [source.sub(/\.bluebook\z/, ".hecksagon")]
                     end
        hecksagons.each { |hecksagon| Kernel.load(hecksagon) if File.exist?(hecksagon) }
      end

      # @api private
      def examine_all(booted, options)
        known_domains = booted.flat_map { |_, registry| registry.bluebooks.keys + registry.hecksagons.keys }.to_set
        global_emitted_events = booted.flat_map do |_, registry|
          registry.bluebooks.values.flat_map { |chapter| Bluebook::ModelCheck.emitted_events(chapter) }
        end.to_set

        booted.reduce(true) do |all_ok, (name, registry)|
          domain_passes?(name, registry, options,
                         known_domains: known_domains, global_emitted_events: global_emitted_events) && all_ok
        end
      end

      # Runs `Bluebook::ModelCheck` over one booted domain's chapters, prints its
      # findings against the allowlist, and reports whether it passes.
      #
      # @param name [String] the domain's display name, for the header and the
      #   `ALLOWED_FINDINGS` lookup
      # @param registry [Runtime::Registry] a booted registry holding the domain's chapters
      # @param options [Options] the run's configuration
      # @param known_domains [Set<String>] every bluebook and hecksagon name booted this run
      # @param global_emitted_events [Set<String>] every event any booted chapter emits
      # @return [Boolean] false if an allowlist entry is stale; otherwise true when no
      #   error-severity finding is left
      def domain_passes?(name, registry, options, known_domains:, global_emitted_events:)
        puts "── #{name}"

        rust_target = rust_target?(name, options.rust_dir)
        chapters = registry.bluebooks.values
        findings = chapters.flat_map do |chapter|
          Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name), known_domains: known_domains,
                                             global_emitted_events: global_emitted_events,
                                             rust_target: rust_target,
                                             strict: options.strict, profile: options.profile,
                                             translations: registry.translations.select { |t| t.domain == chapter.name })
        end

        allowed = Bluebook::ModelCheck::ALLOWED_FINDINGS.fetch(name, [])
        matched, findings = findings.partition { |f| allowed.include?([f.kind, f.subject]) }
        matched.each { |f| puts "   ALLOWLISTED  #{f}" }

        stale = allowed - matched.map { |f| [f.kind, f.subject] }
        unless stale.empty?
          puts "   STALE ALLOWLIST ENTRIES (no longer found — remove them): #{stale.inspect}"
          return false
        end

        passes?(findings, "   clean — #{chapters.size} chapter(s), no dead states, no unreachable protocol steps")
      end

      # Examines the language's own `Bluebook` and `World` chapters through
      # `MetaValidator.grammar_registry`, the judged graph its conformance specs use,
      # because any one grammar file booted alone is a fraction of the language.
      #
      # @param options [Options] the run's configuration
      # @return [Boolean] true when neither chapter has an error-severity finding
      def examine_language(options)
        ok = true
        ["Bluebook", "World"].each do |name|
          chapter = Bluebook::MetaValidator.grammar_registry.bluebook(name)
          next unless chapter

          puts "── #{name} (the language itself)"
          findings = Bluebook::ModelCheck.call(chapter, strict: options.strict, profile: options.profile)
          ok = passes?(findings, "   clean — no dead states, no unreachable protocol steps") && ok
        end
        ok
      end

      # @api private
      def passes?(findings, clean_line)
        if findings.empty?
          puts clean_line
          return true
        end

        errors, warnings = findings.partition { |f| f.severity == :error }
        puts "   #{errors.size} error(s), #{warnings.size} warning(s)"
        findings.each { |f| puts "     #{f}" }
        errors.empty?
      end

      # Says whether the domain has a Cargo feature, which makes a
      # `rust_reserved_name` finding an error for it.
      #
      # The check reads `rust/Cargo.toml` through the repository-only fuzzing
      # tooling, so it is loaded only when there is a `rust/` to read.
      #
      # @param name [String] the domain's display name
      # @param rust_dir [String, nil] the repository's `rust/` directory; nil without a
      #   checkout
      # @return [Boolean] true when `rust_dir` declares a feature named after the domain
      def rust_target?(name, rust_dir)
        return false unless rust_dir

        require_relative "../fuzzing/target_capabilities"
        Fuzzing::TargetCapabilities.rust_feature?(name, rust_dir)
      end

      # The directory holding a domain's bluebooks: `<domain>/bluebook/` or the
      # domain directory itself, the same rule `Corpus.bluebook_dir` applies.
      #
      # @param domain_path [String] a domain directory path
      # @return [String, nil] the directory of the first `.bluebook` found, or nil when
      #   neither place holds one
      def bluebook_dir(domain_path)
        [File.join(domain_path, "bluebook"), domain_path].each do |dir|
          files = Dir[File.join(dir, "*.bluebook")]
          return File.dirname(files.first) unless files.empty?
        end
        nil
      end
    end
  end
end
