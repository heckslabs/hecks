require "hecks/adapters/driving/resident/paths"

module Hecks
  module Adapters
    module Driving
      module Resident
        # How many residents stand, and how many may. A resident that is not first in a crowd
        # ends before it loads anything, and a launcher that sees the crowd does not start one, so a
        # ninth checkout pays its cold boots and not a load that is thrown away.
        #
        # It uses only the standard library: the launcher asks before it loads anything.
        module Crowd
          # How many residents may stand when the Hecks world has not said, and no resident has
          # written what the world says.
          DEFAULT_CAP = 8

          module_function

          # @param except [String, nil] a lock file to leave out: the asker's own
          # @return [Integer] how many other residents hold their locks
          def standing(except = nil)
            Dir.glob(File.join(Paths.directory, "*.lock")).count do |file|
              next false if file == except

              File.open(file) { |other| !other.flock(File::LOCK_EX | File::LOCK_NB) }
            rescue SystemCallError
              false
            end
          end

          # @return [Integer] how many residents may stand: what the last resident read from the
          #   world, else the default
          def cap
            Integer(File.read(File.join(Paths.directory, "cap")).strip)
          rescue SystemCallError, ArgumentError
            DEFAULT_CAP
          end

          # Keeps the cap the world declared, for the launchers and residents that ask before
          # they load. It is written through a temp file and renamed, so a resident that asks while
          # another writes never reads half a number.
          def remember(number)
            file = File.join(Paths.directory, "cap")
            temp = "#{file}.#{Process.pid}.tmp"
            File.write(temp, number.to_i.to_s)
            File.rename(temp, file)
          rescue SystemCallError
            nil
          end

          # How long a lock file is left after a resident last took it.
          LOCK_KEPT = 24 * 60 * 60

          # Removes the lock files of residents that are gone: nobody holds the lock, no socket or
          # process id stands beside it, and no resident has taken it for a day (a resident touches
          # its lock when it takes it). A removed checkout would otherwise leave its lock behind.
          #
          # @param now [Time] the time to judge by
          # @return [void]
          def sweep(now = Time.now)
            Dir.glob(File.join(Paths.directory, "*.lock")).each do |file|
              remove_if_gone(file) if now - File.mtime(file) > LOCK_KEPT
            rescue SystemCallError
              next
            end
          end

          # @return [void] removes the lock file when its lock is free and no socket or id stands
          def remove_if_gone(file)
            File.open(file) do |lock|
              stem = file.delete_suffix(".lock")
              free = lock.flock(File::LOCK_EX | File::LOCK_NB)
              File.delete(file) if free && !File.exist?("#{stem}.sock") && !File.exist?("#{stem}.pid")
            end
          end

          # @param root [String] the checkout asking
          # @return [Boolean] whether other residents already fill the cap
          def crowded?(root) = standing(Paths.lock(root)) >= cap
        end
      end
    end
  end
end
