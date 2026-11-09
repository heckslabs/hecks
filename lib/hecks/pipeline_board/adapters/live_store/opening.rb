# frozen_string_literal: true

require "digest"
require_relative "../probe"
require_relative "../boot_lock"
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
        # old runtime serves until the new one is ready. A reload that fails leaves the old runtime
        # serving and is tried again after the retry window; `problem` says why.
        #
        # The replaced runtime is not closed: a runtime has no close, and the Sqlite handles and the
        # relay thread it holds cannot be released without one. They go when the runtime is
        # collected, and the board's own restart (`board_restart`: memory or age) bounds what a
        # long run of reloads keeps meanwhile. Boots take turns through {BootLock}.
        class Opening
          RETRY_SECONDS = 60
          CHECK_SECONDS = 30
          WAIT_SECONDS = 25
          # The files that declare a domain and the ports and adapters it plugs into.
          DECLARATIONS = "**/*.{bluebook,hecksagon,world,adapter,port}"
          # Where the checkout keeps the shared ports and adapters `Hecks.describe` loads for its
          # domain (the nearest ancestor of the domain directory holding a `ports` or `adapters`
          # folder). The bluebooks the domain attaches are read from the board's own code, not from
          # the checkout, so they are not watched: the board's own restart picks them up.
          SHARED_ROOTS = %w[lib/hecks/ports lib/hecks/adapters].freeze

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

          # @return [String, nil] why the last reload failed while the old runtime serves, nil when
          #   the runtime is current or none has opened yet
          def problem
            @lock.synchronize { "reload of #{@root} failed: #{@failed[:message]}" if @runtime && @failed }
          end

          private

          # The fingerprint a boot is judged against is the one of the files it read: it replaces
          # the last one only when the boot succeeds, so a reload that fails is tried again once
          # the retry window passes, and meanwhile the old runtime serves.
          def start
            return @thread if @thread&.alive?
            return @thread unless wanted?

            reading = fingerprint
            @thread = Thread.new { boot_into(reading) }
          end

          def wanted?
            return !backing_off? unless @runtime

            !backing_off? && changed?
          end

          def backing_off? = @failed && @clock.call - @failed[:at] < @retry_seconds

          def changed?
            return false if @checked && @clock.call - @checked < @check_seconds

            @checked = @clock.call
            fingerprint != @fingerprint
          end

          def boot_into(reading)
            booted = BootLock.exclusive { @booter.call(@directory) }
            @lock.synchronize do
              @runtime = booted
              @fingerprint = reading
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

          # A digest of the path, size and time of each declaration file the checkout's domain
          # reads: the files under its own directory and under the shared roots it attaches.
          def fingerprint
            files = watched.flat_map { |dir| Dir.glob(File.join(dir, DECLARATIONS)) }.uniq.sort
            Digest::SHA256.hexdigest(files.map { |file| stamp(file) }.join("\n"))
          rescue SystemCallError
            nil
          end

          # The directories the domain's declarations come from: its own, and the checkout's
          # shared bluebooks (the language and framework bluebooks it attaches), when it has them.
          def watched
            [@directory, *SHARED_ROOTS.map { |dir| File.join(@root, dir) }].select { |dir| File.directory?(dir) }
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
