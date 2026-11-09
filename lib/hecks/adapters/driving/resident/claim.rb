require "hecks/adapters/driving/resident/paths"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The claim to start a checkout's resident. When the code changes the resident retires and a
        # burst of launchers finds none; exactly one of them takes the claim and starts the
        # replacement, and the rest boot on their own at once. The resident that starts removes the
        # claim when it holds the lock; a claim whose resident never came is taken over after
        # ten seconds.
        #
        # It uses only the standard library: the launcher asks before it loads anything.
        module Claim
          # Seconds a claim stands before another launcher may take it over.
          SECONDS = 10

          module_function

          # @param root [String] the checkout
          # @param again [Boolean] whether to take over a stale claim once
          # @return [Boolean] whether this launcher holds the claim and should start the resident
          def take?(root, again: true)
            File.open(Paths.claim(root), File::CREAT | File::EXCL | File::WRONLY, 0o600) { true }
          rescue Errno::EEXIST
            again && stale?(root) && take?(root, again: false)
          rescue SystemCallError
            false
          end

          # @return [Boolean] whether the claim has stood too long, and is removed for the caller to
          #   take over
          def stale?(root)
            return false if Time.now - File.mtime(Paths.claim(root)) < SECONDS

            File.delete(Paths.claim(root))
            true
          rescue SystemCallError
            true
          end
        end
      end
    end
  end
end
