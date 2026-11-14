# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"
require_relative "claude_closing_message"
require_relative "claude_jobs"
require_relative "dispatching/work_items"
require_relative "dispatching/landed_since"

module Hecks
  module Adapters
    # The `TurnFacts` port's adapter for `Coder::Turn`: what is true of a run whose session is
    # ending a turn. It reads the run, the Work item the run serves, a landing of that item's
    # branch since it started, and the session's closing message.
    #
    # It reads and judges nothing: whether the turn may end is the Coder bluebook's. A run it
    # cannot find is refused, and the bluebook ends that turn.
    class TurnFacts
      # The punctuation and markup around a word, as in `submitted.` or `**blocked**`.
      EDGES = /\A\W+|\W+\z/

      # @param registry [Runtime::Registry, nil] the booted registry, read for runs and Work items
      # @param aggregate [Object, nil] unused
      # @param closing [#of] answers a session's closing message whole, empty when it has none
      # @param jobs [#closing] answers the tail of a session's last words, the fallback
      # @param landed [#call, nil] answers the commit a Work item's branch landed as since it
      #   started, given the item's key and the run's directory; reads the registry when nil
      def initialize(registry: nil, aggregate: nil, closing: ClaudeClosingMessage.new, jobs: ClaudeJobs.new, landed: nil)
        @registry = registry
        @closing = closing
        @jobs = jobs
        @landed = landed || method(:landed_since)
      end

      # @param held [Hash] the Turn: `run` the key of the run, and `again`
      # @return [Hash{Symbol => Object}] `role:` the part the run plays, `held:` whether its Work
      #   item is started, `landed:` whether its branch landed since then, `reviewing:` whether a
      #   plan review it asked for is open, `again:` as the turn holds it, `question:` the first
      #   line of the closing message that begins with a bracket, and `word:` its last word
      # @raise [ConsoleCapture::Failure] when no started run has that key
      def measure_turn(**held)
        key = plain(held[:run]).to_s
        run = started_run(key)
        raise ConsoleCapture::Failure, "no started run is named #{key}" unless run

        run_facts(run).merge(work_facts(run, key), words(field(run, :session).to_s), again: plain(held[:again]) == true)
      end

      private

      def run_facts(run)
        role = field(run, :works_as).to_s.then { |part| part.empty? ? field(run, :agent).to_s : part }
        { role: role, reviewing: field(run, :reviewing) == true }
      end

      # The Work item is the one the run names, else the one its key names.
      def work_facts(run, key)
        work = field(run, :work).to_s.then { |named| named.empty? ? key : named }
        { held: status_of(work) == "started", landed: !@landed.call(work, field(run, :repo)).to_s.empty? }
      end

      # The closing message as the transcript holds it, else the tail the job keeps.
      def words(session)
        text = @closing.of(session).then { |whole| whole.strip.empty? ? @jobs.closing(session).to_s : whole }
        question = text.each_line.map(&:strip).find { |line| line.start_with?("[") }
        { question: question.to_s, word: last_word(text) }
      end

      def last_word(text)
        last = text.split.last.to_s
        last.gsub(EDGES, "")
      end

      def started_run(key)
        rows("Hecks", "AgentRun").reverse.find { |run| field(run, :run).to_s == key && field(run, :status) == "started" }
      end

      def status_of(work)
        item = rows("Tickets", "Work").find { |entry| field(entry, :work).to_s == work }
        item ? field(item, :status).to_s : ""
      end

      def landed_since(work, repo)
        Dispatching::LandedSince.new(Dispatching::WorkItems.new(@registry), repo: repo).call(work)
      end

      def rows(domain, name)
        declared = @registry&.bluebook(domain)&.aggregates || []
        aggregate = declared.find { |candidate| candidate.hecks_name == name }
        aggregate ? @registry.repository(domain, aggregate).all : []
      end

      def field(record, name) = StartedWork.value(record, name)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
