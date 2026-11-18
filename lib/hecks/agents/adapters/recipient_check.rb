# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/claude_executable"
require "hecks/hecks/adapters/claude_resolving_shell"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching/work_items"

module Hecks
  module Adapters
    # The `Recipients` port's adapter for `Message`: says whether a message's recipient is a run
    # with a live session, the one kind of recipient whose session hears its inbox.
    #
    # It reads the AgentRun ledger through {Dispatching::WorkItems}, which only reads, and the
    # `claude agents` listing, and writes nothing. Its one judgement is the wording of a refusal: a
    # run that is started and holds a session is answered, and every other recipient is refused
    # with a line naming what it is instead (a run with no live session, the session of a run, a
    # session with no run, or nothing known).
    class RecipientCheck
      # A recipient that is no run with a live session, or one this boot cannot judge. Its `kind`
      # is the cause as a code (`ended`, `session-of-run`, `no-run`, `unknown`, `no-ledger`), so a
      # policy can tell them apart without the sentence.
      class Unaddressable < StandardError
        # @return [String] the cause, as a code
        attr_reader :kind

        # @param kind [String] the cause, as a code
        # @param sentence [String] the refusal, naming what the recipient is instead
        def initialize(kind, sentence)
          @kind = kind
          super(sentence)
        end
      end

      # @param registry [Runtime::Registry, nil] whose AgentRun ledger is read
      # @param runs [#call, nil] stand-in: answers each run's key with its `status:` and `session:`
      # @param listed [#call, nil] stand-in: answers whether `claude agents` lists a session id
      def initialize(registry: nil, runs: nil, listed: nil)
        @registry = registry
        @read_runs = runs
        @listed = listed
      end

      # @param recipient [Hash, String] the run the message is for
      # @return [Hash{Symbol => Hash}] `recipient:` the run, when it has a live session
      # @raise [Unaddressable] naming why the recipient is no run with a live session
      def recipient(recipient:, **)
        raise Unaddressable.new("no-ledger", NO_LEDGER) unless ledger?

        id = plain(recipient)
        run = runs[id]
        return { recipient: { value: id } } if live?(run)

        raise refusal(id, run)
      end

      # The refusal of a boot that holds no AgentRun ledger: `exe/hecks agents` boots Agents alone.
      NO_LEDGER = "the AgentRun ledger is not booted here, so no recipient can be judged: " \
                  "send with exe/hecks Message.send!, which boots the Hecks domain"

      private

      def ledger?
        return true if @read_runs

        hecks = @registry&.bluebook("Hecks")
        hecks ? hecks.aggregates.any? { |aggregate| aggregate.hecks_name == "AgentRun" } : false
      end

      def live?(run) = run && run[:status] == "started" && !run[:session].to_s.empty?

      def refusal(id, run)
        return Unaddressable.new("ended", "the run #{id} has no live session (#{run[:status]})") if run

        holder = holder_of(id)
        return Unaddressable.new("session-of-run", "#{id} is the session of run #{holder}; send to the run") if holder
        return Unaddressable.new("no-run", "no run has that id; the session #{id} has no AgentRun") if listed?(id)

        Unaddressable.new("unknown", "no run or session has that id: #{id}")
      end

      # The started run whose session the id names, in full or by its short form.
      def holder_of(id)
        found = runs.find { |_, run| live?(run) && run[:session].to_s.start_with?(id) }
        found&.first
      end

      def runs = (@runs ||= (@read_runs ? @read_runs.call : Dispatching::WorkItems.new(@registry).runs))

      def listed?(id)
        @listed ? @listed.call(id) : !listing.find(id).nil?
      rescue ConsoleCapture::Failure
        false
      end

      def listing
        ClaudeSessionListing.new(
          ClaudeExecutable::COMMAND,
          shell: ClaudeResolvingShell.new(executable: ClaudeExecutable.new(candidates: ClaudeExecutable::CANDIDATES))
        )
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
