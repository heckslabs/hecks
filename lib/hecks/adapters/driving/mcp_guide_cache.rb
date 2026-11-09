require "digest"
require "fileutils"
require "json"
require_relative "../../cache_dir"
require_relative "../../storehouse"
require_relative "../../bluebook/meta_validator/verdict_cache"

module Hecks
  module Adapters
    module Driving
      # Remembers the command guide a commands server builds for `tools/list`, so a server that
      # starts
      # again does not boot its domain to describe its commands. A client waits only a moment for a
      # server's tools, and a boot at that point costs more than the wait.
      #
      # An entry is keyed by the domain directory's files, a digest of the hecks code, and the
      # allowed commands, so a change to any of them builds a new guide. The file is JSON, read only
      # from a directory and a file that only this user can write (the verdict cache's own check),
      # and only when it is a list of strings: a guide is text an agent reads as instructions.
      module McpGuideCache
        module_function

        # The guide for a domain and its allowed commands, from the cache or else from the block,
        # which is then remembered. A cache that cannot be written is not an error: the next start
        # builds the guide again.
        #
        # @param domain [String] the domain directory the guide describes
        # @param commands [Array<String>] the allowed command names
        # @yieldreturn [Array<String>, nil] the guide, built when none is remembered
        # @return [Array<String>, nil] the guide
        def remember(domain, commands)
          file = File.join(dir, "#{key(domain, commands)}.json")
          cached = read(file)
          return cached if cached

          guide = yield
          write(file, guide) if guide.is_a?(Array) && guide.any?
          guide
        end

        # @return [String] the directory entries live in
        def dir = Hecks::CacheDir.path("mcp_guides")

        # @param domain [String] the domain directory
        # @param commands [Array<String>] the allowed command names
        # @return [String] a hex SHA-256 over the domain's files, the hecks code and the commands
        def key(domain, commands)
          parts = [Storehouse.fingerprint(domain), Bluebook::MetaValidator::VerdictCache.code_digest,
                   commands.sort.join(",")]
          Digest::SHA256.hexdigest(parts.join("\0"))
        end

        # @param file [String] an entry's path
        # @return [Array<String>, nil] the guide, or nil when absent, untrusted or malformed
        def read(file)
          return unless File.file?(file) && Bluebook::MetaValidator::VerdictCache.trusted?(file)

          guide = JSON.parse(File.read(file))
          return unless guide.is_a?(Array) && guide.all?(String)

          File.utime(nil, nil, file)
          guide
        rescue StandardError
          nil
        end

        # @param file [String] an entry's path
        # @param guide [Array<String>] the guide to remember
        # @return [void]
        def write(file, guide)
          FileUtils.mkdir_p(dir, mode: 0o700)
          temp = "#{file}.#{Process.pid}.tmp"
          File.write(temp, JSON.generate(guide), perm: 0o600)
          File.rename(temp, file)
          prune
        rescue StandardError
          FileUtils.rm_f(temp) if temp
        end

        # How long an entry that is not read stays, and the most entries kept. Every edit to the
        # hecks code in any checkout makes a new key, so entries only pile up without this.
        KEPT_FOR = 30 * 24 * 60 * 60
        MOST_ENTRIES = 200

        # The directory the guides were kept in when a server was called a door; nothing writes it
        # now, and its entries age out with the rest.
        LEGACY_DIR = "mcp_door_guides".freeze

        # Removes the entries unread for `KEPT_FOR`, keeps the newest `MOST_ENTRIES` of the
        # rest, and clears temp files a dead writer left. Also ages out the legacy directory.
        #
        # @param now [Time] the time to judge by
        # @return [void]
        def prune(now: Time.now)
          [dir, Hecks::CacheDir.path(LEGACY_DIR)].each { |directory| prune_directory(directory, now) }
        end

        # @return [void] removes one directory's aged files and the ones past the newest few
        def prune_directory(directory, now)
          files = Dir.glob(File.join(directory, "*")).select { |file| File.file?(file) }
          aged, fresh = files.partition { |file| now - mtime(file, now) > kept_for(file) }
          (aged + newest_first(fresh, now).drop(MOST_ENTRIES)).each { |file| FileUtils.rm_f(file) }
        end

        # @return [Array<String>] the entries (not temp files), the most recently used first
        def newest_first(files, now)
          files.reject { |file| file.end_with?(".tmp") }.sort_by { |file| -mtime(file, now).to_f }
        end

        # @return [Integer] seconds a file stays unread: an hour for a temp file, else `KEPT_FOR`
        def kept_for(file) = file.end_with?(".tmp") ? 3600 : KEPT_FOR

        # @return [Time] when the file was last read or written; `now` when it cannot be told
        def mtime(file, now)
          File.mtime(file)
        rescue SystemCallError
          now
        end
      end
    end
  end
end
