# frozen_string_literal: true

module Hecks
  module Adapters
    class GitLanding
      # A ticket's wait for the front of the line.
      #
      # It blocks on the lock of the ticket just ahead, so the kernel wakes it when that ticket is
      # released or its process dies, and on the ticket's mailbox, so a train that settles the
      # branch
      # for it wakes it too. A timer wakes it only at the moment a silent ticket would go stale, or
      # when its own wait runs out. Each change of place is said once, naming the holder.
      class Waiting
        # How a holder's wording reads in a position message.
        LANDING_FOR = / \(landing for (.*)\)\z/

        # Raised when the wait ran out before the ticket reached the front.
        class Expired < RuntimeError; end

        # What the wait ended with.
        #
        # @!attribute [r] verdict
        #   @return [Hash, nil] the train's verdict, when it settled the branch instead
        # @!attribute [r] note
        #   @return [String, nil] a sentence for the report: the wait, the place and what was
        # superseded
        # @!attribute [r] waited
        #   @return [Integer] whole seconds the wait lasted
        Turn = Struct.new(:verdict, :note, :waited)

        # @param line [Line] the line
        # @param ticket [Ticket] the ticket waiting
        # @param patience [Numeric] seconds the wait may last
        # @param say [#call] told each change of place
        # @param foreign [ForeignHold] what else can hold the landing
        def initialize(line, ticket, patience:, say:, foreign:)
          @line = line
          @ticket = ticket
          @say = say
          @foreign = foreign
          @until = clock + patience
          @started = clock
          @notes = []
        end

        # @return [Turn] reached the front, or settled by a train
        # @raise [Expired] when the wait ran out
        def run
          events = Thread::Queue.new
          mailbox = Thread.new { events << [:verdict, @ticket.verdict] }
          verdict = await(events)
          verdict ? Turn.new(verdict, note, seconds) : front
        ensure
          mailbox&.kill
        end

        private

        def front
          budget = -> { @until - clock }
          cleared = @foreign.clears_within?(@ticket.name, budget, @say)
          raise Expired, "waited #{waited} for the shell lock or an older landing" unless cleared

          @line.promote(@ticket)
          Turn.new(nil, note, seconds)
        end

        def await(events)
          loop do
            standing = @line.standing(@ticket)
            @notes.concat(standing.notes)
            return nil if standing.ahead.empty?

            announce(standing.ahead)
            event = pause(standing, events)
            return event.last if event&.first == :verdict
          end
        end

        def pause(standing, events)
          raise Expired, "waited #{waited} behind #{@last}" if @until <= clock

          watcher = Thread.new do
            standing.ahead.last.wait_gone
            events << [:ahead]
          end
          events.pop(timeout: [@line.stale_in(standing.ahead), @until - clock].min)
        ensure
          watcher&.kill
        end

        def announce(ahead)
          @last = @line.wording(ahead.first.data)
          said = "#{ordinal(ahead.size + 1)} in line; holder #{@last.sub(LANDING_FOR, ' has landed for \\1')}"
          return if @said == said

          @said = said
          @notes << said
          @say.call("#{@ticket.data[:branch]} is #{said}")
        end

        def note
          return nil if @notes.empty?

          "#{@notes.join("; ")}; waited #{waited}"
        end

        def seconds = (clock - @started).round

        def waited
          seconds = self.seconds
          seconds < 120 ? "#{seconds}s" : "#{seconds / 60}m #{seconds % 60}s"
        end

        def ordinal(number)
          suffix = number.between?(11, 13) ? "th" : { 1 => "st", 2 => "nd", 3 => "rd" }.fetch(number % 10, "th")
          "#{number}#{suffix}"
        end

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
