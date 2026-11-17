# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    module Codebase
      # The line of jobs waiting for a heavy-job place: one ticket file per waiter, ordered by
      # priority and then by arrival, so the place goes to the head of the line and no later job
      # overtakes it.
      #
      # A ticket's name is `<priority>-<arrival ns>-<pid>`, fixed width so names sort as written.
      # The waiter holds a kernel `flock` on its ticket while it waits, so the ticket of a waiter
      # that died is found by a lock that can be taken, and is removed: a dead head never blocks
      # the line. A ticket is made under a hidden name, locked, and only then renamed into the
      # line, so no other waiter ever sees a live ticket whose lock is not yet held. A steady
      # stream of train gates or urgent jobs can keep ordinary jobs waiting; their give-up bounds
      # that.
      class SlotQueue
        # The directory under the places' directory that holds the tickets.
        WAITING = "waiting"

        # Priority of a push train's job: it goes ahead of every other job.
        TRAIN = 0

        # Priority of a job a landing was given by name: behind the train's, ahead of ordinary ones.
        URGENT = 1

        # Priority of every other job. A ticket named `1-` was ordinary before `URGENT` existed.
        ORDINARY = 2

        # The environment variable that names a job urgent, set to `URGENT_VALUE` by the caller that
        # carries a landing's urgency.
        URGENT_MARK = "HECKS_HEAVY_PRIORITY"

        # The value of `URGENT_MARK` that makes a job urgent.
        URGENT_VALUE = "urgent"

        # The git configuration the train's push carries, which git passes on to the hook and to
        # every process the hook starts, in `GIT_CONFIG_PARAMETERS`.
        TRAIN_MARK = "hecks.trainCarry"

        # @param base [#[]] the environment
        # @return [Integer] `TRAIN` for a job started by the push train's push, `URGENT` for a job
        #   marked urgent, else `ORDINARY`
        def self.priority_of(base)
          return TRAIN if base["GIT_CONFIG_PARAMETERS"].to_s.include?(TRAIN_MARK)

          base[URGENT_MARK] == URGENT_VALUE ? URGENT : ORDINARY
        end

        # @param dir [String] the directory the places live in
        # @param priority [Integer] the waiter's priority, lower goes first
        # @param arrival [#call] answers the arrival time in nanoseconds
        def initialize(dir, priority: ORDINARY, arrival: -> { Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) })
          @dir = File.join(dir, WAITING)
          @priority = priority
          @arrival = arrival
        end

        # Takes a ticket at the end of its priority's line. A line that cannot be opened leaves the
        # waiter without a ticket, and it is then always at the head.
        #
        # @return [SlotQueue] self
        def join
          FileUtils.mkdir_p(@dir)
          @file = File.new(File.join(@dir, ".#{Process.pid}-#{rand(1 << 32)}"), File::CREAT | File::RDWR, 0o600)
          @file.flock(File::LOCK_EX)
          @name = format("%<priority>d-%<ns>020d-%<pid>010d", priority: @priority, ns: @arrival.call, pid: Process.pid)
          File.rename(@file.path, File.join(@dir, @name))
          self
        rescue SystemCallError
          @file&.close
          @file = nil
          self
        end

        # @return [Boolean] whether no live ticket stands ahead of this one
        def head?
          return true unless @file

          tickets.each { |name| return name == @name if name == @name || alive?(name) }
          true
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

        def tickets = Dir.children(@dir).reject { |name| name.start_with?(".") }.sort

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
