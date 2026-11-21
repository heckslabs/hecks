# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/claude_executable"
require "hecks/hecks/adapters/claude_resolving_shell"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching/work_items"
require "hecks/agents/adapters/recipient_check/hand_runs"
require "hecks/agents/adapters/recipient_check/senders"
require "hecks/agents/adapters/recipient_check/sender_proof"

module Hecks
  module Adapters
    # The `Recipients` port's adapter for `Message`: says whether a message's recipient is a run
    # with a live session, the one kind of recipient whose session hears its inbox.
    #
    # It reads the AgentRun ledger through {Dispatching::WorkItems}, which only reads, the
    # `HandRun` rows of a session registered by hand ({HandRuns}), and the `claude agents` listing,
    # and writes nothing. An AgentRun is looked for first; a key no AgentRun holds is found as a
    # hand run while `claude agents` lists its session. Its one judgement is the wording of a
    # refusal: a run that is started and holds a session is answered, and every other recipient is
    # refused with a line naming what it is instead (a run with no live session, a hand run whose
    # session is not listed, the session of a run, a session with no run, or nothing known).
    class RecipientCheck
      # A recipient that is no run with a live session, or one this boot cannot judge. Its `kind`
      # is the cause as a code (`ended`, `hand-unlisted`, `session-of-run`, `no-run`, `unknown`,
      # `no-ledger`), so a policy can tell them apart without the sentence.
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
      # @param hand_runs [#call, nil] stand-in: answers each hand run's key with its `session:`
      # @param session [#call, nil] stand-in: answers the sending session id
      def initialize(registry: nil, runs: nil, listed: nil, hand_runs: nil, session: nil)
        @registry = registry
        @read_runs = runs
        @listed = listed
        @hand_runs = HandRuns.new(registry, hand_runs)
        @senders = Senders.new(registry)
        @proof = SenderProof.new(runs: method(:runs), hand_runs: @hand_runs, session: session)
      end

      # @param sender [Hash, String] the sender as the message names it
      # @param recipient [Hash, nil] the run the message is for, passed back for the next step
      # @return [Hash{Symbol => Hash}] `verified:` "true" when the sending session is registered
      #   under that name, otherwise "false"; never raises
      def sender(sender:, recipient: nil, **)
        { sender: { value: plain(sender) }, recipient: recipient,
          verified: { value: (ledger? && @proof.verified?(plain(sender))).to_s } }
      end

      # @param recipient [Hash, String] the run the message is for
      # @return [Hash{Symbol => Hash}] `recipient:` the run, when it has a live session
      # @raise [Unaddressable] naming why the recipient is no run with a live session
      def recipient(recipient:, **)
        raise Unaddressable.new("no-ledger", NO_LEDGER) unless ledger?

        id = plain(recipient)
        run = runs[id]
        return { recipient: { value: id } } if live?(run) || (run.nil? && (hand_live?(id) || held?(id)))

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

      # A name that has sent a message and is no run: its replies wait unread in its inbox.
      def held?(id) = @senders.spoke?(id)

      def hand_live?(id)
        session = @hand_runs.session(id)
        !session.empty? && listed?(session)
      end

      def refusal(id, run)
        return Unaddressable.new("ended", "the run #{id} has no live session (#{run[:status]})") if run
        return hand_unlisted(id) unless @hand_runs.session(id).empty?

        holder = holder_of(id)
        return Unaddressable.new("session-of-run", "#{id} is the session of run #{holder}; send to the run") if holder
        return Unaddressable.new("no-run", "no run has that id; the session #{id} has no AgentRun") if listed?(id)

        Unaddressable.new("unknown", "no run has that id: #{id}, and no session has it either")
      end

      def hand_unlisted(id)
        session = @hand_runs.session(id)
        Unaddressable.new("hand-unlisted", "the hand run #{id}'s session #{session} is not listed by claude agents")
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
