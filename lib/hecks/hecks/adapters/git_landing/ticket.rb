# frozen_string_literal: true

require "json"
require_relative "verdict"

module Hecks
  module Adapters
    class GitLanding
      # One place in the landing line: a file named by its sequence number, its branch, its process
      # and its start time.
      #
      # The owner holds an exclusive `flock` on the file for as long as the ticket lives, so a
      # waiter
      # blocks on the ticket ahead of it and the kernel wakes it the moment that ticket is
      # released or
      # its process dies. The owner also touches the file on a timer: its modification time is the
      # heartbeat, and a ticket that stops beating while still locked belongs to a hung process.
      class Ticket
        # The suffix every ticket file carries.
        SUFFIX = ".ticket"

        # Makes a ticket and takes its lock.
        #
        # @param path [String] the new file
        # @param data [Hash] what it records: branch, pid, start time, checkout, onto and whether
        #   it is ready
        # @return [Ticket] the ticket, locked by this process
        def self.create(path, data)
          io = File.new(path, File::RDWR | File::CREAT | File::EXCL)
          io.flock(File::LOCK_EX)
          io.write(JSON.generate(data))
          io.flush
          new(path, io, Verdict.create(wake_path(path)))
        end

        # @param path [String] a ticket file
        # @return [String] the mailbox beside it
        def self.wake_path(path) = path.sub(/#{SUFFIX}\z/o, ".verdict")

        # @return [String] the ticket file
        attr_reader :path

        # @param path [String] the ticket file
        # @param io [IO, nil] the owner's locked handle
        # @param verdict [Verdict, nil] the owner's mailbox
        def initialize(path, io = nil, verdict = nil)
          @path = path
          @io = io
          @verdict = verdict
        end

        # @return [String] the file name
        def name = File.basename(@path)

        # @return [Integer] the place in the line this ticket was given
        def sequence = name.to_i

        # @return [Hash] what the ticket records; a branch of "another landing" when it cannot be
        #   read
        def data
          JSON.parse(File.read(@path), symbolize_names: true)
        rescue JSON::ParserError, SystemCallError
          { branch: "another landing" }
        end

        # Rewrites the record in place, so the lock on the file is kept.
        #
        # @param changes [Hash] the keys to set
        # @return [void]
        def update(**changes)
          File.write(@path, JSON.generate(data.merge(changes)))
        end

        # Touches the file; its modification time becomes the heartbeat.
        #
        # @param time [Time] the heartbeat
        # @return [void]
        def beat(time)
          File.utime(time, time, @path)
        rescue SystemCallError
          nil
        end

        # Starts beating on a timer, until the ticket is closed.
        #
        # @param every [Numeric] seconds between beats
        # @param clock [#call] answers the current Time
        # @return [void]
        def beat_every(every, clock)
          @beater = Thread.new do
            loop do
              sleep(every)
              beat(clock.call)
            end
          end
        end

        # @param now [Time] the current time
        # @return [Float] seconds since the last heartbeat, infinite when the ticket is gone
        def silence(now)
          now.to_f - File.mtime(@path).to_f
        rescue Errno::ENOENT
          Float::INFINITY
        end

        # @return [Boolean] whether a live process holds the lock
        def held?
          File.open(@path, File::RDONLY) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) == false }
        rescue Errno::ENOENT
          false
        end

        # Blocks until the owner releases the lock or dies.
        #
        # @return [void]
        def wait_gone
          File.open(@path, File::RDONLY) { |file| file.flock(File::LOCK_EX) }
        rescue Errno::ENOENT
          nil
        end

        # Blocks until the train delivers a verdict to this ticket's owner.
        #
        # @return [Hash, nil] the verdict
        def verdict = @verdict&.read

        # Tells the owner of this ticket how its branch fared.
        #
        # @param payload [Hash] `landed:` the answer, or `refused:` the reason
        # @return [void]
        def deliver(payload)
          Verdict.deliver(self.class.wake_path(@path), payload)
        end

        # Stops beating and lets go of the lock and the mailbox.
        #
        # @return [void]
        def close
          @beater&.kill
          @verdict&.close
          @io&.close
        end

        # Deletes the files of a ticket.
        #
        # @return [void]
        def remove
          File.delete(@path)
          Verdict.new(self.class.wake_path(@path), nil).remove
        rescue Errno::ENOENT
          nil
        end
      end
    end
  end
end
