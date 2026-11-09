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
          # they load.
          def remember(number)
            File.write(File.join(Paths.directory, "cap"), number.to_i.to_s)
          rescue SystemCallError
            nil
          end

          # @param root [String] the checkout asking
          # @return [Boolean] whether other residents already fill the cap
          def crowded?(root) = standing(Paths.lock(root)) >= cap
        end
      end
    end
  end
end
