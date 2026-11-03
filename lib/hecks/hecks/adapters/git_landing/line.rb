# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "ticket"
require_relative "numbering"

module Hecks
  module Adapters
    class GitLanding
      # The landing line of one repository: ticket files in `queue/` under the main checkout's git
      # directory, numbered by a counter that only grows, so first come is first served across
      # processes. The ticket at the front holds the one place to land.
      #
      # Every read or change of the line happens inside an `flock` on a guard file. The front
      # ticket
      # feeds the legacy claim file, which landers that still read it keep honouring.
      class Line
        # What a look at the line finds ahead of a ticket.
        #
        # @!attribute [r] ahead
        #   @return [Array<Ticket>] the live tickets in front, in order
        # @!attribute [r] notes
        #   @return [Array<String>] the abandoned tickets removed on the way
        Standing = Struct.new(:ahead, :notes)

        # The minutes without a heartbeat after which a ticket is abandoned, when no setting names
        # another.
        DEFAULT_STALE_MINUTES = 30

        # @param git_dir [String] the main checkout's git directory
        # @param stale_minutes [Numeric, nil] the heartbeat window; the default when nil
        # @param clock [#call] answers the current Time
        # @param heartbeat [Numeric] seconds between a holder's heartbeats
        def initialize(git_dir, stale_minutes: nil, clock: -> { Time.now }, heartbeat: 15)
          @git_dir = git_dir
          @root = File.join(git_dir, "hecks-landing")
          @dir = File.join(@root, "queue")
          @stale = (stale_minutes || DEFAULT_STALE_MINUTES).to_f * 60
          @clock = clock
          @heartbeat = heartbeat
          @numbers = Numbering.new(@dir, @root)
        end

        # Takes the next place in the line.
        #
        # @param branch [String] the branch the ticket stands for
        # @param jump [Boolean] take the place right behind the front ticket, ahead of those
        #   waiting
        # @param details [Hash] more for the ticket to record: `checkout`, `onto`, `ready`
        # @return [Ticket] the ticket, locked and beating
        def join(branch, jump: false, **details)
          guarded do
            record = details.merge(branch: branch, pid: Process.pid, at: now.to_f)
            ticket = Ticket.create(@numbers.path(tickets, branch, jump, now), record)
            ticket.beat(now)
            ticket.beat_every(@heartbeat, @clock)
            ticket
          end
        end

        # Looks at the tickets in front of one, removing any that were abandoned: its process is
        # gone,
        # or it holds the lock but has not beaten for the stale window.
        #
        # @param ticket [Ticket] the ticket asking
        # @return [Standing] the live tickets ahead and the sentences about the abandoned ones
        def standing(ticket)
          guarded do
            ahead = tickets.select { |other| other.sequence < ticket.sequence }.map { |other| [other, lapse(other)] }
            notes = ahead.filter_map { |other, why| supersede(other, why) if why }
            Standing.new(ahead.reject { |_, why| why }.map(&:first), notes)
          end
        end

        # Makes a ticket the holder: stamps the time it began and feeds the legacy claim.
        #
        # @param ticket [Ticket] the ticket at the front
        # @return [void]
        def promote(ticket)
          guarded do
            ticket.update(turn_at: now.to_f)
            File.write(legacy, JSON.generate(token: ticket.name, branch: ticket.data[:branch], pid: Process.pid, at: now.to_f))
          end
        end

        # Gives a ticket up: closes it, deletes its files, and clears the legacy claim when it fed
        # it.
        #
        # @param ticket [Ticket] the ticket
        # @return [void]
        def leave(ticket)
          guarded do
            File.delete(legacy) if fed_by?(ticket)
            ticket.close
            ticket.remove
          end
        end

        # The next ticket behind one that declared itself ready and has not been settled yet.
        #
        # @param ticket [Ticket] the holder
        # @return [Ticket, nil] the first such ticket
        def next_ready(ticket)
          guarded do
            tickets.find { |other| other.sequence > ticket.sequence && waiting_ready?(other) }
          end
        end

        # @param data [Hash] a ticket's record
        # @return [String] its branch and how long it has been at the front
        def wording(data)
          minutes = ((now.to_f - data.fetch(:turn_at) { data[:at] }.to_f) / 60).floor
          "#{data[:branch]} (landing for #{minutes} minute#{"s" unless minutes == 1})"
        end

        # @return [Float] seconds until the soonest of some tickets would go stale, at least a
        #   second
        def stale_in(tickets)
          [tickets.map { |held| @stale - held.silence(now) }.min.to_f, 1].max
        end

        # @return [String] the legacy claim file
        def legacy = File.join(@git_dir, "hecks-landing.claim")

        private

        def now = @clock.call

        def fed_by?(ticket)
          File.exist?(legacy) && JSON.parse(File.read(legacy))["token"] == ticket.name
        rescue JSON::ParserError
          false
        end

        # Why a ticket is abandoned, or nil while it is alive and beating.
        def lapse(ticket)
          return "its process is gone" unless ticket.held?

          quiet = ticket.silence(now)
          "no heartbeat for #{(quiet / 60).floor} minutes" if quiet > @stale
        end

        def supersede(ticket, why)
          sentence = "superseded the abandoned landing of #{wording(ticket.data)} (#{why})"
          File.delete(legacy) if fed_by?(ticket)
          ticket.remove
          sentence
        end

        def tickets
          names = Dir.children(@dir).grep(/#{Ticket::SUFFIX}\z/o)
          names.sort.map { |name| Ticket.new(File.join(@dir, name)) }
        end

        def waiting_ready?(ticket)
          held = ticket.data
          held[:ready] && !held[:handled] && ticket.held?
        end

        def guarded
          FileUtils.mkdir_p(@dir)
          File.open(File.join(@root, "guard"), File::RDWR | File::CREAT) do |file|
            file.flock(File::LOCK_EX)
            yield
          end
        end
      end
    end
  end
end
