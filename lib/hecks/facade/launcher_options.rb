require_relative "../ports/identity_generation"
require_relative "../runtime/errors"
require_relative "cli_door"

module Hecks
  module Facade
    # What a domain's world file adds to its generated launcher, all of it opt-in.
    #
    # A `.world` that declares a `launcher` setting switches these on for that chapter; a
    # domain without one keeps the launcher's plain forms exactly:
    #
    #     launcher "Launcher", run_keys: true, failure_states: %w[flagged failed],
    #                          names: { "mcp" => "serve_mcp" }
    #
    # - **run_keys** mints the `run` key of a creating command that was given none.
    # - **failure_states** are the lifecycle states `--wait` reports as a failure (exit 1).
    # - **names** maps a launcher name to the command it stands for (see `CliProjector`).
    module LauncherOptions
      SETTING = "launcher".freeze
      WAIT    = "--wait".freeze
      RUN_KEY = "run.value".freeze

      module_function

      # Reads a chapter's `launcher` setting.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param chapter [String] the chapter the command line speaks to
      # @return [Hash{Symbol => Object}, nil] the setting, or nil when the chapter did not opt in
      def settings(runtime, chapter)
        return unless runtime.respond_to?(:registry)

        found = runtime.registry.world(chapter)&.for_verb(SETTING)
        found.nil? || found.empty? ? nil : found
      end

      # The options the launcher's projection is asked for: the program's name, the chapter's
      # launcher names, and whether run keys are minted (so help shows them optional).
      #
      # @param settings [Hash, nil] the chapter's `launcher` setting
      # @param program [String] how the caller was invoked
      # @return [Hash{Symbol => Object}] the options `Projector::CliProjector` reads
      def projection(settings, program)
        { program: program, names: settings && settings[:names], mint_run_keys: settings && settings[:run_keys] }
      end

      # Takes `--wait` out of a verb's words, unless the verb declares a `wait` argument of its own.
      #
      # `--wait=false` (or `no`, `0`, `off`) is a `--wait` that was switched off; a bare `--wait`
      # may be followed by its Boolean word.
      #
      # @param spec [Hash] the verb's projected spec
      # @param words [Array<String>] the words after the verb
      # @return [Array(Array<String>, Boolean)] the remaining words, and whether `--wait` was given
      # @raise [Runtime::TypeMismatch] if `--wait=` carries something that is not a Boolean word
      def take_wait(spec, words)
        return [words, false] unless words.any? { |word| wait_word?(word) }
        return [words, false] if spec[:arguments].any? { |argument| argument[:path].split(".").first == "wait" }

        wait  = false
        rest  = []
        queue = words.dup
        until queue.empty?
          word = queue.shift
          wait_word?(word) ? wait ||= CliDoor.boolean(wait_value(word, queue)) : rest << word
        end
        [rest, wait]
      end

      # @api private
      def wait_word?(word) = word == WAIT || word.start_with?("#{WAIT}=")

      # The Boolean word a `--wait` carries: after `=`, or the next word when it is one.
      # @api private
      def wait_value(word, queue)
        return word.split("=", 2).last if word.include?("=")

        CliDoor::BOOLEAN_WORDS.key?(queue.first.to_s.downcase) ? queue.shift : "true"
      end

      # Whether a question's text answer reports a gap, which `--wait` turns into a failing exit.
      #
      # The coverage checks end their report with a `GAP (n)` heading; a non-zero count is a
      # finding, and a CI stage that waits on the question fails on it.
      #
      # @param text [String, nil] the question's text answer
      # @return [Boolean] whether a `GAP (n)` heading with n above zero is in the text
      def gap_reported?(text)
        text.is_a?(String) && text.match?(/^GAP \((?!0\))\d+\)/)
      end

      # Mints the `run` key a creating command was not given, when the domain opted in.
      #
      # An explicit key always wins. Nothing is minted for a command that acts on an existing
      # record. When no identity adapter is bound the run is refused, saying to name a key,
      # rather than sent on without one.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param spec [Hash] the verb's projected spec
      # @param args [Hash] the parsed arguments
      # @param settings [Hash, nil] the chapter's `launcher` setting
      # @return [Array(Hash, String)] the arguments, and the key minted (nil when none was)
      # @raise [Runtime::NotFound] if a key is owed but no identity adapter is bound
      def run_key(runtime, spec, args, settings)
        return [args, nil] unless settings && settings[:run_keys] && spec[:creates]
        return [args, nil] unless spec[:arguments].any? { |argument| argument[:path] == RUN_KEY }
        return [args, nil] if args.key?(:run) || !runtime.respond_to?(:registry)

        key = Ports::IdentityGeneration.uuid(runtime.registry)
        [args.merge(run: { value: key }), key]
      rescue Runtime::WiringError => e
        raise Runtime::NotFound, "cannot mint a run key (#{e.message.lines.first.strip}); name one with run=<key>"
      end

      # Whether a settled record sits in one of the chapter's failure states.
      #
      # @param aggregate [Bluebook::Aggregate, nil] the record's aggregate
      # @param state [Hash, nil] the record's state
      # @param settings [Hash, nil] the chapter's `launcher` setting
      # @return [Boolean] false when the aggregate has no lifecycle
      def failed?(aggregate, state, settings)
        field = aggregate&.lifecycle&.field
        return false unless field && state

        Array(settings && settings[:failure_states]).map(&:to_s).include?(state[field.to_sym].to_s)
      end
    end
  end
end
