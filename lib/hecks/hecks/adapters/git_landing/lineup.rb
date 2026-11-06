# frozen_string_literal: true

require_relative "line"
require_relative "waiting"
require_relative "foreign_hold"
require_relative "train"
require_relative "../console_capture"
require_relative "../../../indifferent_key"

module Hecks
  module Adapters
    class GitLanding
      # A landing's way through the line: a ticket in order, a wait for the front, the landing
      # itself,
      # then the ticket given back; or a train that settles the tickets behind it.
      #
      # The limits come from the world's `landing "Queue", stale_minutes: n, wait_minutes: n`; the
      # `tune` hash overrides any of them (`stale_minutes`, `wait_minutes`, `heartbeat`, `clock`,
      # `say`,
      # `locks`, `mine`, `gate`).
      class Lineup
        # The minutes a landing waits for its turn, when no setting names another.
        DEFAULT_WAIT_MINUTES = 15

        # @param git_dir [String] the main checkout's git directory
        # @param setting [Hash, nil] the world's `landing` setting
        # @param tune [Hash] overrides of the limits and the collaborators
        def initialize(git_dir, setting: nil, **tune)
          @tune = { stale_minutes: read(setting, :stale_minutes), wait_minutes: read(setting, :wait_minutes),
                    locks: ForeignHold.locks(git_dir, read(setting, :shell_lock)) }.compact.merge(tune)
          @line = Line.new(git_dir, stale_minutes: @tune[:stale_minutes], clock: @tune.fetch(:clock) { -> { Time.now } },
                                    heartbeat: @tune.fetch(:heartbeat, 15))
        end

        # Takes a place, waits for the front, and runs the block there; or, when a train settled
        # the
        # branch while it waited, answers what the train answered and runs nothing.
        #
        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @param checkout [String] the worktree it lands from
        # @yieldparam note [String, nil] what the wait was: the place, the holder, what was
        #   superseded
        # @yieldparam waited [Integer] whole seconds the wait lasted
        # @return [Hash] the landing answer
        # @raise [ConsoleCapture::Failure] when the wait runs out, or the train refused the branch
        def stand(branch, onto:, checkout:)
          ticket = @line.join(branch, checkout: checkout, onto: onto, ready: true)
          turn = waiting(ticket).run
          turn.verdict ? carried(turn) : yield(turn.note, turn.waited)
        rescue Waiting::Expired => e
          raise ConsoleCapture::Failure, "queue busy: #{branch} is not landed: #{e.message}; land again when the line clears"
        ensure
          @line.leave(ticket) if ticket
        end

        # Takes the front place and lands every ready branch behind it.
        #
        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param onto [String] the branch the train lands on
        # @param land [#call] `(checkout, branch, onto)` lands one branch
        # @return [String] the train's report, opened by what the wait was
        def convoy(git, checkout, onto:, land:)
          ticket = @line.join("train", jump: true, checkout: checkout, onto: onto, ready: false)
          turn = waiting(ticket).run
          crew = Train::Crew.new(@line, ticket, land, @tune.fetch(:gate, Train::QUICK_GATE))
          [Train.new(git, checkout, crew, onto: onto).run, turn.note].compact.join("; ")
        ensure
          @line.leave(ticket) if ticket
        end

        private

        def waiting(ticket)
          Waiting.new(@line, ticket, patience: @tune.fetch(:wait_minutes, DEFAULT_WAIT_MINUTES).to_f * 60,
                                     say: @tune.fetch(:say) { ->(text) { warn(text) } }, foreign: foreign)
        end

        def foreign
          stale = (@tune[:stale_minutes] || Line::DEFAULT_STALE_MINUTES).to_f * 60
          options = { locks: @tune.fetch(:locks, []), stale: stale }
          options[:mine] = @tune[:mine] if @tune[:mine]
          ForeignHold.new(@line.legacy, **options)
        end

        def carried(turn)
          verdict = turn.verdict
          raise ConsoleCapture::Failure, verdict[:refused] if verdict[:refused]

          said = verdict[:landed][:report][:value]
          verdict[:landed].merge(report: { value: "#{said}; landed by the train, #{turn.note}" })
        end

        def read(setting, key) = setting && IndifferentKey.read(setting, key)
      end
    end
  end
end
