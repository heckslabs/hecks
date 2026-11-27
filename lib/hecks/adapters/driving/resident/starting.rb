require "fileutils"
require "rbconfig"
require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/outcome"
require "hecks/adapters/driving/resident/crowd"
require "hecks/adapters/driving/resident/claim"
require "hecks/adapters/driving/resident/spawn_env"

module Hecks
  module Adapters
    module Driving
      module Resident
        # Starting the resident that will serve the next line. A launcher that a resident served
        # never needs it, so the client loads this file only when it has to start one (it takes the
        # standard library's `fileutils` and four files of its own).
        module Starting
          # The resident's server, relative to a checkout's `lib`.
          SERVER = "hecks/adapters/driving/resident/server.rb".freeze

          module_function

          # Starts the resident, unless the cap of residents is met; it takes its own lock, so a
          # second start exits at once. It leaves the launcher's session, so it keeps no terminal,
          # and it starts with the same plain environment whoever starts it ({SpawnEnv}), so no
          # caller's odd environment becomes its own.
          #
          # @param root [String] the checkout
          # @param script [String] the launcher's own path
          # @return [String] the outcome: `started`, `none` when one is already coming up (its lock
          #   is held, or another launcher has claimed the start), or `refused:crowded`
          def call(root, script)
            return Outcome::NONE if lock_held?(root)
            return Outcome.refused("crowded") if Crowd.crowded?(root)
            return Outcome::NONE unless Claim.take?(root)

            Process.detach(Process.spawn(SpawnEnv.build, *server_command(root, script), **detached))
            Outcome::STARTED
          end

          # The resident runs the code of the checkout it serves, never its starter's: one that ran
          # another checkout's code would load that checkout's vendored adapters beside its own.
          # A checkout with no resident of its own is served by the starter's.
          #
          # @return [Array<String>] the command that runs the resident for the checkout
          def server_command(root, script)
            lib = File.join(root, "lib")
            lib = File.expand_path("../../../..", __dir__) unless File.file?(File.join(lib, SERVER))
            [RbConfig.ruby, "-I", lib, File.join(lib, SERVER), root, File.realpath(script)]
          end

          # @return [Hash] the spawn options: nothing is inherited from the launcher but the
          #   plain environment {SpawnEnv} names, and no stream
          def detached = { unsetenv_others: true, in: File::NULL, out: File::NULL, err: File::NULL }

          # @return [Boolean] whether a resident holds the checkout's lock, so it is up or coming up
          def lock_held?(root)
            FileUtils.mkdir_p(Paths.directory, mode: 0o700)
            File.open(Paths.lock(root), File::CREAT | File::RDWR, 0o600) do |lock|
              return !lock.flock(File::LOCK_EX | File::LOCK_NB)
            end
          rescue SystemCallError
            true
          end
        end
      end
    end
  end
end
