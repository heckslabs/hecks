# frozen_string_literal: true

require "fileutils"
require_relative "slot_ticket"

module Hecks
  module Adapters
    module Codebase
      # The line of jobs waiting for a heavy-job place: one ticket file per waiter, ordered by
      # rank and then by arrival, so the place goes to the head of the line and no later job
      # overtakes it. The rank is the priority (train, then urgent, then the rest).
      #
      # A landing's job (a finished branch waiting to land, which a refusal costs an hour) ranks as
      # an ordinary one until it has waited `landing_age` seconds (20 minutes) and then ahead of
      # every ordinary job, newer or older, behind the train's and urgent ones ({SlotTicket}).
      #
      # A ticket's name is `<priority>-<arrival ns>-<pid>`. A waiter that rejoins keeps its first
      # arrival ({SlotWait}), so the line is first come, first served across retries. The waiter
      # holds a kernel `flock` on its ticket, so a dead waiter's ticket is found by a lock that can
      # be taken and removed.
      class SlotQueue
        # The directory under the places' directory that holds the tickets.
        WAITING = "waiting"

        # Priority of a push train's job: it goes ahead of every other job.
        TRAIN = 0

        # Priority of a job a landing was given by name: behind the train's, ahead of ordinary ones.
        URGENT = 1

        # Priority of every other job. A ticket's leading digit is its priority.
        ORDINARY = 2

        # Priority of a landing's job: ordinary until it has aged, then ahead of ordinary jobs.
        LANDING = 3

        # Seconds a landing's job waits before it ranks ahead of ordinary jobs.
        LANDING_AGE = 1200

        # The environment variable that says a job belongs to a landing, set to `LANDING_VALUE`.
        KIND_MARK = "HECKS_HEAVY_KIND"

        # The value of `KIND_MARK` for a landing.
        LANDING_VALUE = "landing"

        # The heavy-job class of a landing's shallow check.
        LANDING_JOB = "shallow_check"

        # The environment variable that names a job urgent, set to `URGENT_VALUE` by the caller that
        # carries a landing's urgency.
        URGENT_MARK = "HECKS_HEAVY_PRIORITY"

        # The value of `URGENT_MARK` that makes a job urgent.
        URGENT_VALUE = "urgent"

        # The git configuration the train's push carries, which git passes on to the hook and to
        # every process the hook starts, in `GIT_CONFIG_PARAMETERS`.
        TRAIN_MARK = "hecks.trainCarry"

        # @param base [#[]] the environment
        # @param job [String, nil] the job's class
        # @return [Integer] `TRAIN` for a job started by the push train's push, `URGENT` for a job
        #   marked urgent, `LANDING` for a landing's job, else `ORDINARY`
        def self.priority_of(base, job = nil)
          return TRAIN if base["GIT_CONFIG_PARAMETERS"].to_s.include?(TRAIN_MARK)
          return URGENT if base[URGENT_MARK] == URGENT_VALUE

          base[KIND_MARK] == LANDING_VALUE || job == LANDING_JOB ? LANDING : ORDINARY
        end

        # @return [Integer] the time in nanoseconds
        def self.now = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)

        # @param dir [String] the directory the places live in
        # @param priority [Integer] the waiter's priority, lower goes first
        # @param arrival [#call] answers the arrival time in nanoseconds
        # @param landing_age [Numeric] seconds a landing's ticket waits before it ranks ahead
        def initialize(dir, priority: ORDINARY, landing_age: LANDING_AGE, arrival: -> { SlotQueue.now })
          @dir = File.join(dir, WAITING)
          @priority = priority
          @arrival = arrival
          @landing_age = landing_age
        end

        # Takes a ticket at the end of its priority's line. A line that cannot be opened leaves the
        # waiter without a ticket, and it is then always at the head.
        #
        # @return [SlotQueue] self
        def join
          FileUtils.mkdir_p(@dir)
          @file = File.new(File.join(@dir, ".#{Process.pid}-#{rand(1 << 32)}"), File::CREAT | File::RDWR, 0o600)
          @file.flock(File::LOCK_EX)
          @name = SlotTicket.name(@priority, @arrival.call, Process.pid)
          File.rename(@file.path, File.join(@dir, @name))
          self
        rescue SystemCallError
          @file&.close
          @file = nil
          self
        end

        # @return [Boolean] whether no live ticket stands ahead of this one
        def head? = ahead.zero?

        # @return [Integer] how many live tickets stand ahead of this one
        def ahead
          return 0 unless @file

          tickets.take_while { |name| name != @name }.count { |name| alive?(name) }
        end

        # Gives the ticket up.
        #
        # @return [void]
        def leave
          return unless @file

          File.delete(File.join(@dir, @name))
          @file.close
        rescue SystemCallError, IOError
          nil
        end

        private

        def tickets
          now = SlotQueue.now
          Dir.children(@dir).reject { |name| name.start_with?(".") }
             .sort_by { |name| SlotTicket.key(name, now, @landing_age) }
        end

        # Whether the ticket's waiter lives; a ticket whose lock can be taken is a dead waiter's and
        # is removed.
        def alive?(name)
          File.open(File.join(@dir, name)) do |file|
            return true unless file.flock(File::LOCK_EX | File::LOCK_NB)

            File.delete(file.path)
            false
          end
        rescue SystemCallError
          false
        end
      end
    end
  end
end
