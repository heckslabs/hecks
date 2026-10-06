require_relative "interview_draft"
require_relative "interview_session/catalog"
require_relative "interview_session/proposals"
require_relative "interview_session/manual_findings"
require_relative "interview_session/agent_state"

module Hecks
  module CLI
    # One interview, held at a terminal (ADR 0088).
    #
    # hecks drives: it asks the agent for a question, shows it, reads the answer the developer typed
    # back from the expert, records it, asks the agent what the answer names as findings, and puts
    # each to the developer to accept or reject. The agent never dispatches anything. Every SME
    # command is dispatched here, so the domain's own rules are the guard on the interview.
    #
    # With no agent (`--no-ai`), or for a turn the agent could not answer, a plain prompt stands in:
    # a fixed question, and findings typed by the developer.
    class InterviewSession
      include Proposals
      include ManualFindings
      include AgentState

      # @param runtime [Runtime] the booted SME chapter
      # @param agent [#question, #proposals, nil] the interviewer; nil runs the plain prompts
      # @param input [#gets] where the developer types
      # @param output [#puts, #print] where the session speaks
      # @param reference [String] the interview's reference, such as `INT-1`
      # @param subject [String] the domain being discovered, as its bluebook will spell it
      # @param expert [String] who is being interviewed
      def initialize(runtime:, agent:, input:, output:, reference:, subject:, expert:) # rubocop:disable Metrics/ParameterLists -- one keyword per collaborator and setting
        @runtime = runtime
        @agent = agent
        @input = input
        @output = output
        @reference = reference
        @subject = subject
        @expert = expert
        @asked = []
        @number = 0
        @suggested = false
      end

      # Holds the interview until the developer finishes or quits.
      #
      # @return [Result] `concluded` with the plain interview (see `InterviewDraft`), or `cancelled`
      def call
        ::Interview.plan!(reference: @reference, subject: @subject, expert: @expert).begin!
        say("#{NOTICE}\n") if @agent
        say("Type done when there is enough to start, or quit to stop and write nothing.\n")
        turn until finished?
        outcome
      end

      private

      def outcome
        return Result.new(status: :cancelled) if @cancelled

        Result.new(status: :concluded, interview: InterviewDraft.from_record(current))
      end

      def finished? = @finished

      def current = ::Interview.find(@reference)

      def turn
        question = next_question
        say("\n#{question}")
        answer = ask("> ")
        return end_of_input if answer.nil?

        case answer.strip.downcase
        when "" then say("Say what the expert said, or type done.")
        when "done" then conclude
        when "quit" then cancel
        else answered(question, answer.strip)
        end
      end

      def answered(question, answer)
        current.record!(question: question, answer: answer)
        @asked << question
        findings_from(answer)
        suggest_enough
      end

      def next_question
        asked = @asked.dup
        proposed = @agent && ask_agent { @agent.question(state: state, asked: asked) }
        text = proposed&.text
        return text if text && !@asked.include?(text)

        FALLBACK_QUESTIONS.find { |q| !@asked.include?(q) } || FALLBACK_QUESTIONS.last
      end

      def findings_from(answer)
        proposals = @agent && ask_agent { @agent.proposals(prose: answer, state: state) }
        return manual_findings unless proposals

        proposals.each { |proposal| review(proposal) }
      end

      # Runs one call to the agent; a turn it cannot answer is said aloud, and a plain one follows.
      def ask_agent
        yield
      rescue Ports::Agent::Unavailable, Ports::Agent::ValidationError => e
        say("The AI could not answer (#{e.message.lines.first.to_s.strip}). Using a plain prompt for this turn.")
        nil
      end

      def suggest_enough
        return if @suggested || !enough?

        @suggested = true
        say("\nI think we have enough to start. Type done to finish, or keep answering.")
      end

      def enough?
        plain = InterviewDraft.from_record(current)
        InterviewDraft.accepted(plain, :things).any? && InterviewDraft.accepted(plain, :actions).any?
      end

      def conclude
        current.conclude!
        @finished = true
      rescue StandardError => e
        say("Not finished yet: #{reason(e)}.")
      end

      def cancel
        current.cancel!
        @cancelled = @finished = true
        say("Stopped. Nothing was written.")
      end

      def end_of_input
        conclude
        cancel unless @finished
      end

      def accept?(label)
        !%w[n no].include?(ask(label).to_s.strip.downcase)
      end

      def ask(label)
        @output.print(label)
        @input.gets&.chomp
      end

      def say(text) = @output.puts(text)
    end
  end
end
