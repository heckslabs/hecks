require "pathname"
require "stringio"
require_relative "../ports/identity_generation"
require_relative "../runtime/errors"
require_relative "cli_door"

module Hecks
  module Doors
    # What a domain's world file adds to its generated launcher, all of it opt-in.
    #
    # A `.world` that declares a `launcher` setting switches these on for that chapter; a
    # domain without one keeps the launcher's plain forms exactly:
    #
    # - **run_keys** mints the `run` key of a creating command that was given none.
    # - **settled** lists the commands (`aggregate.command`) that always act as if given `--wait`.
    # - **report** lists the settled commands whose answer is the report they recorded, as text.
    # - **names** maps a launcher name to the command it stands for (see `CliProjector`).
    # - **streams** lists the questions `--stream` may tail, one JSON line per new entry.
    # - **maintainer**, **chapters**, **maintainer_chapters** shape the help for its audience.
    module LauncherOptions
      SETTING = "launcher".freeze
      WAIT    = "--wait".freeze
      STREAM  = "--stream".freeze
      RUN_KEY = "run.value".freeze
      # The lifecycle mark naming the states `--wait` reports as a failure (exit 1); the lifecycle
      # says so with `mark :failure, "flagged"` (ADR 0097), so no setting lists them.
      FAILURE_MARK = "failure".freeze
      # What makes a directory a hecks checkout: this file stands beside `lib/`, the same test
      # the Codebase aggregate's `Accept` applies before it runs anything.
      CHECKOUT_MARKER = "hecks.gemspec".freeze
      # `HECKS_MAINTAINER=1` shows the maintainer help anywhere, `0` hides it even in a checkout.
      MAINTAINER_VARIABLE = "HECKS_MAINTAINER".freeze

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

      # Whether the person is working on a hecks checkout: `dir` or a directory above it holds
      # `hecks.gemspec` beside `lib/`. `HECKS_MAINTAINER` overrides the look.
      #
      # @param dir [String] where the command line was typed
      # @param env [#[]] the environment
      # @return [Boolean] true for the maintainer's view of the help
      def maintainer?(dir = Dir.pwd, env = ENV)
        forced = env[MAINTAINER_VARIABLE].to_s
        return forced != "0" unless forced.empty?

        Pathname.new(File.expand_path(dir)).ascend.any? do |root|
          root.join(CHECKOUT_MARKER).exist? && root.join("lib").directory?
        end
      end

      # The help options one audience gets: the aggregates left out of the lists (`maintainer`,
      # shown only in a hecks checkout or to `--maintainer`) and the chapters pointed at
      # (`chapters`, plus `maintainer_chapters` in a checkout). A chapter that did not opt in
      # gets neither.
      #
      # @param settings [Hash, nil] the chapter's `launcher` setting
      # @param maintainer [Boolean] whether the help is for someone working on a hecks checkout
      # @return [Hash{Symbol => Object}] `:hide` and `:chapters`, to merge into the projection
      def audience(settings, maintainer)
        return {} unless settings

        chapters = Array(settings[:chapters]) + (maintainer ? Array(settings[:maintainer_chapters]) : [])
        { hide: maintainer ? [] : Array(settings[:maintainer]).map(&:to_s), chapters: chapters.map(&:to_s) }
      end

      # Runs the block with standard error held back, so the wiring notes hecks prints about its own
      # chapters (a Memory journal loses sagas on restart) do not open a console session. They are
      # for an operator running a stored journal. A raised error still surfaces, unchanged.
      #
      # @param hold [Boolean] whether to hold standard error back; false runs the block as it is
      # @yield the boot
      # @return [Object] the block's value
      def quietly(hold: true)
        return yield unless hold

        shown = $stderr
        $stderr = StringIO.new
        yield
      ensure
        $stderr = shown if hold
      end

      # Takes `--wait` out of a command's words, unless it declares a `wait` argument of its own.
      #
      # `--wait=false` (or `no`, `0`, `off`) is a `--wait` that was switched off; a bare `--wait`
      # may be followed by its Boolean word.
      #
      # @param spec [Hash] the command's projected spec
      # @param words [Array<String>] the words after the command
      # @return [Array(Array<String>, Boolean)] the remaining words, and whether `--wait` was given
      # @raise [Runtime::TypeMismatch] if `--wait=` carries something that is not a Boolean word
      def take_wait(spec, words)
        return [words, false] unless words.any? { |word| wait_word?(word) } && !declares_wait?(spec)

        split_wait(words)
      end

      # Whether the command declares an argument of its own named `wait`.
      # @api private
      def declares_wait?(spec)
        spec[:arguments].any? { |argument| argument[:path].split(".").first == "wait" }
      end

      # The words without `--wait`, and whether it was given.
      # @api private
      def split_wait(words)
        wait  = false
        rest  = []
        queue = words.dup
        until queue.empty?
          word = queue.shift
          wait_word?(word) ? wait ||= CliDoor.boolean(wait_value(word, queue)) : rest << word
        end
        [rest, wait]
      end

      # Whether a command always waits for its reactions, as if `--wait` had been given.
      #
      # @param launcher [Hash, nil] the chapter's `launcher` setting
      # @param spec [Hash] the command's projected spec
      # @return [Boolean] true for a command the setting lists under `settled`
      def settled?(launcher, spec)
        return false unless launcher && spec[:kind] == :command

        Array(launcher[:settled]).map(&:to_s).include?(spec[:short].to_s)
      end

      # Whether a command prints the report it recorded instead of its whole record.
      #
      # @param launcher [Hash, nil] the chapter's `launcher` setting
      # @param spec [Hash] the command's projected spec
      # @return [Boolean] true for a command the setting lists under `report`
      def report?(launcher, spec)
        return false unless launcher && spec[:kind] == :command

        Array(launcher[:report]).map(&:to_s).include?(spec[:short].to_s)
      end

      # Whether a question may be tailed with `--stream`: the chapter's `launcher` setting lists it
      # under `streams`, by the question's own name.
      #
      # @param launcher [Hash, nil] the chapter's `launcher` setting
      # @param spec [Hash] the question's projected spec
      # @return [Boolean] true for a question the setting names
      def streams?(launcher, spec)
        return false unless launcher && spec[:kind] == :query

        Array(launcher[:streams]).map(&:to_s).include?(spec[:command].to_s.split(/[.:]+/).last)
      end

      # Takes `--stream` out of a question's words.
      #
      # @param words [Array<String>] the words after the question
      # @return [Array(Array<String>, Boolean)] the remaining words, and whether `--stream` was
      #   given
      def take_stream(words)
        [words.reject { |word| word == STREAM }, words.include?(STREAM)]
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
      # @param spec [Hash] the command's projected spec
      # @param args [Hash] the parsed arguments
      # @param settings [Hash, nil] the chapter's `launcher` setting
      # @return [Array(Hash, String)] the arguments, and the key minted (nil when none was)
      # @raise [Runtime::NotFound] if a key is owed but no identity adapter is bound
      def run_key(runtime, spec, args, settings)
        return [args, nil] unless key_owed?(runtime, spec, args, settings)

        key = Ports::IdentityGeneration.uuid(runtime.registry)
        [args.merge(run: { value: key }), key]
      rescue Runtime::WiringError => e
        raise Runtime::NotFound, "cannot mint a run key (#{e.message.lines.first.strip}); name one with run=<key>"
      end

      # Whether the command is a creating one of an opted-in chapter, takes a run key and was
      # given none.
      # @api private
      def key_owed?(runtime, spec, args, settings)
        return false unless settings && settings[:run_keys] && spec[:creates]
        return false unless spec[:arguments].any? { |argument| argument[:path] == RUN_KEY }

        !args.key?(:run) && runtime.respond_to?(:registry)
      end

      # Whether a settled record sits in a state its lifecycle marks as a failure.
      #
      # @param aggregate [Bluebook::Aggregate, nil] the record's aggregate
      # @param state [Hash, nil] the record's state
      # @param settings [Hash, nil] the chapter's `launcher` setting
      # @return [Boolean] false when the aggregate has no lifecycle
      def failed?(aggregate, state, settings)
        field = aggregate&.lifecycle&.field
        return false unless field && state && settings

        Array(aggregate.lifecycle.marked(FAILURE_MARK)).include?(state[field.to_sym].to_s)
      end
    end
  end
end
