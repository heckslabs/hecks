require "digest/sha1"
require "hecks/cache_dir"

module Hecks
  module Adapters
    module Driving
      # A resident per checkout holds the loaded declarations of the Hecks domain and runs each
      # launcher line in a fork of itself (ADR 0201). Its client, `Resident::Client`, is the first
      # thing a launcher runs, so everything it requires is standard library.
      module Resident
        # Where a checkout's resident keeps its socket and lock: a private directory under the
        # cache root, so a spec that redirects the cache directory never reaches a developer's
        # resident.
        module Paths
          # A Unix socket's path may not pass 103 bytes on macOS, which counts a terminator in
          # 104, and 107 on Linux.
          LONGEST_SOCKET = 103

          module_function

          # @param script [String] a launcher's path
          # @return [String] the checkout it belongs to: the directory above `exe/`
          def root_for(script) = File.dirname(File.realpath(script), 2)

          # @return [String] the directory the residents' files live in: under `HECKS_CACHE_DIR`
          #   when that names one, as the help cache does, else under the cache root
          def directory
            named = ENV.fetch("HECKS_CACHE_DIR", "")
            named.empty? ? CacheDir.path("resident") : File.join(named, "resident")
          end

          # @param root [String] the checkout
          # @return [String] the file name stem for the checkout, short enough for a socket path
          def stem(root) = File.join(directory, Digest::SHA1.hexdigest(root)[0, 8])

          # @return [String] the resident's socket
          def socket(root) = "#{stem(root)}.sock"

          # @return [String] the lock the one running resident holds
          def lock(root) = "#{stem(root)}.lock"

          # @return [String] the file the running resident writes its process id to
          def pid(root) = "#{stem(root)}.pid"

          # @return [Boolean] whether the socket's path fits in the system's limit
          def usable?(root) = socket(root).bytesize <= LONGEST_SOCKET
        end
      end
    end
  end
end
