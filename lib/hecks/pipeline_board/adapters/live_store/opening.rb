# frozen_string_literal: true

require "digest"
require_relative "../probe"
require_relative "../registry_store"

module Hecks
  module Adapters
    module PipelineBoard
      class LiveStore < RegistryStore
        # The booted runtime of a checkout's Hecks domain. A boot is long, so it runs on its own
        # thread: a reader waits for it a while but its own deadline never ends the boot, and a
        # reader that gives up finds the boot still going. A failed boot is remembered and not
        # tried again for a minute. While the checkout's declaration files stand as they were the
        # runtime is kept; when one changes the domain is booted again in the background and the
        # old runtime serves until the new one is ready.
        class Opening
          RETRY_SECONDS = 60
          CHECK_SECONDS = 30
          WAIT_SECONDS = 15
          # The files that declare a domain.
          DECLARATIONS = "**/*.{bluebook,hecksagon,world,adapter}"

          # @param root [String] the checkout, named in what is raised
          # @param directory [String] the checkout's Hecks domain directory
          # @param booter [#call] takes the directory and answers a booted runtime
          # @param clock [#call] the time in seconds
          def initialize(root:, directory:, booter:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                         timing: {})
            @root = root
            @directory = directory
            @booter = booter
            @clock = clock
            @retry_seconds = timing.fetch(:retry, RETRY_SECONDS)
            @check_seconds = timing.fetch(:check, CHECK_SECONDS)
            @wait_seconds = timing.fetch(:wait, WAIT_SECONDS)
            @lock = Mutex.new
          end

          # Starts the boot without waiting for it.
          # @return [Opening] self
          def warm
            @lock.synchronize { start }
            self
          end

          # @return [Object] the booted runtime
          # @raise [Unavailable] while the first boot is going, and when it failed
          def runtime
            thread = @lock.synchronize { start }
            thread.join(@wait_seconds) if thread && !@runtime
            @lock.synchronize { answer }
          end

          # @return [Runtime::Registry] the registry of the booted runtime
          # @raise [Unavailable] while the first boot is going, and when it failed
          def registry = runtime.registry

          private

          def start
            return @thread if @thread&.alive?
            return @thread unless wanted?

            @fingerprint = fingerprint
            @thread = Thread.new { open }
          end

          def wanted?
            return !backing_off? unless @runtime

            changed?
          end

          def backing_off? = @failed && @clock.call - @failed[:at] < @retry_seconds

          def changed?
            return false if @checked && @clock.call - @checked < @check_seconds

            @checked = @clock.call
            fingerprint != @fingerprint
          end

          def open
            booted = @booter.call(@directory)
            @lock.synchronize do
              @runtime = booted
              @failed = nil
            end
          rescue StandardError => e
            @lock.synchronize { @failed = { at: @clock.call, message: e.message.to_s.tr("\n", " ")[0, 160] } }
          end

          def answer
            return @runtime if @runtime

            raise Unavailable, "the live store at #{@root} did not open: #{@failed[:message]}" if @failed

            raise Unavailable, "the live store at #{@root} is still opening"
          end

          # A digest of the path, size and time of each declaration file of the domain.
          def fingerprint
            files = Dir.glob(File.join(@directory, DECLARATIONS))
            Digest::SHA256.hexdigest(files.map { |file| stamp(file) }.join("\n"))
          rescue SystemCallError
            nil
          end

          def stamp(file)
            stat = File.stat(file)
            [file, stat.size, stat.mtime.to_f].join(" ")
          end
        end
      end
    end
  end
end
