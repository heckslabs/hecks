require "digest/sha1"
require "hecks/cache_dir"
require "hecks/adapters/driving/resident/wire"

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

          # @return [String] the protocol version the files are named for: {Wire::PROTOCOL}, unless
          #   `HECKS_RESIDENT_PROTOCOL` names another (a spec's way to stand in for an older
          #   resident)
          def protocol
            named = ENV.fetch("HECKS_RESIDENT_PROTOCOL", "")
            named.empty? ? Wire::PROTOCOL.to_s : named[0, 6]
          end

          # @param root [String] the checkout
          # @return [String] the checkout's part of every file name, the same for every protocol
          def prefix(root) = File.join(directory, Digest::SHA1.hexdigest(root)[0, 8])

          # @param root [String] the checkout
          # @return [String] the file name stem for the checkout and the protocol, short enough for
          #   a socket path
          def stem(root) = "#{prefix(root)}-p#{protocol}"

          # @return [String] the resident's socket
          def socket(root) = "#{stem(root)}.sock"

          # @return [String] the file the running resident writes its protocol and process id to
          def version(root) = "#{stem(root)}.version"

          # @return [String] the file a launcher leaves when a resident was too busy to answer it
          def busy(root) = "#{stem(root)}.busy"

          # @return [String] the file the resident writes the names of the variables it was born
          #   under beyond a plain resident's (empty for a plain one)
          def baseline(root) = "#{stem(root)}.baseline"

          # @return [String] the file the launchers keep the times a line was refused on its
          #   environment in, one per line
          def envs(root) = "#{stem(root)}.envs"

          # @return [Boolean] whether a resident of another protocol stands for the checkout: one
          #   that holds a lock of the checkout's, not this protocol's
          def other_protocol?(root)
            own = lock(root)
            Dir.glob("#{prefix(root)}*.lock").any? { |file| file != own && held?(file) }
          rescue SystemCallError
            false
          end

          # @return [String, nil] why there is no resident to ask: `unsafe` when something that is
          #   not this user's own stands at the socket's path, `protocol` when a resident of
          #   another protocol stands for the checkout (it is not asked: it speaks differently,
          #   and exits when it has been idle), nil when there is none
          def absent_reason(root)
            return "unsafe" if socket_present?(root)

            other_protocol?(root) ? "protocol" : nil
          end

          # @return [Boolean] whether some process holds the lock file's lock
          def held?(file) = File.open(file) { |lock| !lock.flock(File::LOCK_EX | File::LOCK_NB) }

          # @return [String] the lock the one running resident holds
          def lock(root) = "#{stem(root)}.lock"

          # @return [String] the file the running resident writes its process id to
          def pid(root) = "#{stem(root)}.pid"

          # @return [String] the file a launcher creates while it starts the checkout's resident,
          #   so a burst of launchers starts one and not one each
          def claim(root) = "#{stem(root)}.claim"

          # @param name [String] a setting the resident read from the Hecks world
          # @param default [Numeric] what a launcher uses until a resident has written one
          # @return [Float] the setting as the last resident wrote it
          def recall(name, default)
            Float(File.read(File.join(directory, name)).strip)
          rescue SystemCallError, ArgumentError
            Float(default)
          end

          # Keeps a setting the world declared for the launchers, which ask before they load. It is
          # written through a temp file and renamed, so a launcher never reads half a number.
          #
          # @return [void]
          def remember(name, value)
            file = File.join(directory, name)
            temp = "#{file}.#{Process.pid}.tmp"
            File.write(temp, value.to_s)
            File.rename(temp, file)
          rescue SystemCallError
            nil
          end

          # @return [Boolean] whether a resident may be asked for or started: the socket's path
          #   fits in the system's limit, the cache directory is one a later launcher finds again,
          #   and the directories are this user's and closed to everyone else
          def usable?(root) = unusable_reason(root).nil?

          # @return [String, nil] why no resident may be asked for or started: `path` (the socket's
          #   path is too long), `unstable` (the cache root changes each launcher) or `unsafe` (a
          #   directory is not this user's alone); nil when one may
          def unusable_reason(root)
            return "path" if socket(root).bytesize > LONGEST_SOCKET
            return "unstable" unless persistent?

            "unsafe" unless trusted_directory?(directory) && trusted_directory?(File.dirname(directory))
          end

          # @return [Boolean] whether something stands at the resident's socket path
          def socket_present?(root) = File.symlink?(socket(root)) || File.exist?(socket(root))

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
