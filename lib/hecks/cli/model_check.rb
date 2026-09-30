require_relative "../../hecks"
require_relative "../bluebook/model_check"

module Hecks
  module CLI
    # The command behind `bin/model_check` and `hecks model_check`: static analysis
    # over the IR, printed per domain, exiting non-zero when any error-severity
    # finding is left — unreachable lifecycle states, dead transitions, unreached
    # saga states, dispatches to a nonexistent command, handlers for an event
    # nothing emits. The runtime checks none of these; a dead transition never
    # fires, in silence.
    #
    # Given domain paths it checks just those, cross-domain; given none it sweeps
    # the repository's corpus and the language's own chapters, which needs `root:`.
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

      def take_profile(argv)
        inline = argv.find { |arg| arg.start_with?("--profile=") }
        index = argv.index("--profile")
        return unless inline || index

        name = inline ? inline.delete_prefix("--profile=") : argv[index + 1].to_s
        argv.delete(inline) if inline
        argv.slice!(index, 2) if index
        name.to_sym
      end

      # Examines every named domain against one shared set of known domains and
      # emitted events, so a cross-domain reaction between two of them is checked.
      def check_domains(domain_args, options)
        booted = domain_args.map do |domain_arg|
          [File.basename(domain_arg.chomp("/")), boot(bluebook_dir(domain_arg.chomp("/")) || domain_arg)]
        end
        examine_all(booted, options)
      end

      # Two passes over the same boots, because a single boot's own registry cannot
      # answer whether a target domain exists anywhere in the corpus.
      def check_corpus(root, options)
        require_relative "../corpus"
        targets = Corpus.model_check_members(root: root).map { |member| [member.stem, Corpus.source_of(member)] }
        booted = targets.map { |name, source| [name, boot(source)] }
        ok = examine_all(booted, options)
        examine_language(options) && ok
      end

      # `root:` is the source's parent, so a member declaring
      # `uses_embryonaut_bluebook` can vendor from it.
      def boot(source)
        root = File.directory?(source) ? File.dirname(source) : nil
        registry = Runtime::Registry.new(root: root)
        Hecks.with_registry(registry) { load_source(source) }
        registry
      end

      # @api private
      def load_source(source)
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

        # A port attaches to its aggregate from the hecksagon, not the bluebook, so a
        # deaf-policy check that skipped it would miss a policy reacting to an event
        # nothing emits. Recording a bind builds IR only; no adapter resolves here. A chapter
        # that ships its ports beside its bluebook (`<name>.ports.hecksagon`) is read with them.
        hecksagons = if File.directory?(source)
                       Dir.glob(File.join(source, "*.hecksagon"))
                     else
                       [".hecksagon", ".ports.hecksagon"].map { |suffix| source.sub(/\.bluebook\z/, suffix) }
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

      def domain_passes?(name, registry, options, known_domains:, global_emitted_events:)
        puts "── #{name}"

        rust_target = rust_target?(name, options.rust_dir)
        chapters = registry.bluebooks.values
        findings = chapters.flat_map do |chapter|
          Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name), known_domains: known_domains,
                                             global_emitted_events: global_emitted_events,
                                             rust_target: rust_target,
                                             strict: options.strict, profile: options.profile)
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

      # Checked through `MetaValidator.grammar_registry`, the judged graph its
      # conformance specs use, because any one grammar file booted alone is a
      # fraction of the language.
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

      # The repository-only fuzzing tooling is loaded lazily, only when there is a
      # `rust/` to read.
      def rust_target?(name, rust_dir)
        return false unless rust_dir

        require_relative "../fuzzing/target_capabilities"
        Fuzzing::TargetCapabilities.rust_feature?(name, rust_dir)
      end

      # The same rule `Corpus.bluebook_dir` applies.
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
