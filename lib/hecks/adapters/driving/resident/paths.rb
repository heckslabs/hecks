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

          # @return [Boolean] whether a resident may be asked for or started: the socket's path
          #   fits in the system's limit, the cache directory is one a later launcher finds again,
          #   and the directories are this user's and closed to everyone else
          def usable?(root)
            socket(root).bytesize <= LONGEST_SOCKET && persistent? && trusted_directory?(directory) &&
              trusted_directory?(File.dirname(directory))
          end

          # @return [Boolean] whether the cache directory is named, or is the stable cache root: a
          #   launcher with a fresh temporary directory each time would start a resident each time
          def persistent? = !ENV.fetch("HECKS_CACHE_DIR", "").empty? || CacheDir.stable?

          # @return [Boolean] whether `path` is absent, or is a directory of this user's that no one
          #   else can write to
          def trusted_directory?(path)
            stat = File.lstat(path)
            stat.directory? && stat.uid == Process.uid && stat.mode.nobits?(0o022)
          rescue Errno::ENOENT
            true
          rescue SystemCallError
            false
          end

          # @return [Boolean] whether the resident's socket, if there is one, is this user's own and
          #   closed to everyone else, so nothing is sent to a socket someone else put there
          def trusted_socket?(root)
            stat = File.lstat(socket(root))
            stat.socket? && stat.uid == Process.uid && stat.mode.nobits?(0o022)
          rescue SystemCallError
            false
          end
        end
      end
    end
  end
end
