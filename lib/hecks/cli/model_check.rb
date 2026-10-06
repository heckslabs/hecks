require_relative "../../hecks"
require_relative "../bluebook/model_check"
require_relative "model_check/sources"
require_relative "model_check/examination"

module Hecks
  module CLI
    # The command behind `hecks model_check`: static analysis
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

      extend Sources
      extend Examination

      module_function

      # Runs the model check `argv` describes and exits with its verdict.
      #
      # @param argv [Array<String>] `--strict`, `--profile NAME`, `--wait` and domain paths;
      #   `--wait` is accepted for the launcher's sake, as the verdict is always the exit status
      # @param program [String] the name the usage message calls this command by
      # @param root [String, nil] the repository root, for the corpus sweep and the
      #   Rust-target check; nil when there is no checkout
      # @return [void]
      # @raise [SystemExit] always: 0 when clean, 1 with findings or a usage error,
      #   2 for an unknown profile
      def call(argv, program:, root: nil)
        argv = argv.dup
        strict = !argv.delete("--strict").nil?
        argv.delete("--wait")
        options = Options.new(strict, known_profile(take_profile(argv)), root && File.join(root, "rust"))
        finish(run_check(argv, options, program, root))
      end

      # @api private
      def known_profile(profile)
        return profile if profile.nil? || Bluebook::ModelCheck::PROFILES.include?(profile)

        warn "unknown profile #{profile.inspect} (known: #{Bluebook::ModelCheck::PROFILES.join(", ")})"
        exit 2
      end

      # @api private
      def run_check(argv, options, program, root)
        if argv.any? then check_domains(argv, options)
        elsif root then check_corpus(root, options)
        else abort "usage: #{program} [--strict] [--profile client] <domain> [<domain> …]"
        end
      rescue Bluebook::DSL::Malformed => e
        abort "#{program}: #{e.message}"
      end

      # @api private
      def finish(clean)
        puts
        puts clean ? "No dead states, no unreachable protocol steps." : "THE MODEL HAS FINDINGS."
        exit(clean ? 0 : 1)
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
    end
  end
end
