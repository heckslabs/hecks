require "digest"
require "fileutils"
require "json"
require_relative "../../cache_dir"
require_relative "../../version"
require_relative "verdict_cache/tagging"
require_relative "verdict_cache/prebuilt"

module Hecks
  module Bluebook
    module MetaValidator
      # Cross-process store of the meta-domain's chapter verdicts, so a boot
      # judges only the chapters no earlier process has judged.
      #
      # Only chapter verdicts live here; `Assembly.call` still runs every boot
      # and a miss judges as a cold process does. The file name carries a digest
      # of the judging code (`lib/` outside `CONSUMER_TREES`, the Ruby and Hecks
      # versions, `FORMAT`); each entry is keyed by the chapter IR's SHA-256.
      # The file is tagged JSON, never `Marshal`, read only from a private,
      # user-owned directory: a forged "no refusals" entry would skip validation.
      #
      #   VerdictCache.record(key, held)
      #   VerdictCache.flush  # also runs at process exit
      module VerdictCache
        extend Tagging
        extend Prebuilt

        module_function

        # Bumped when the encoding or the entry shape changes.
        FORMAT = 1

        # The subtrees of `lib/` that read the language and never judge it: they
        # project, serve or deploy from a chapter, and nothing the judge runs
        # calls into them. An edit there leaves every verdict as it was, so
        # their files stay out of the key. Paths are relative to `lib/hecks`.
        CONSUMER_TREES = %r{\A/hecks/(?:bench|cli|codemod|deploy|doc|doors|fuzzing|projections|
                            quality_control|release)(?:/|\.rb\z)}x

        # Files older than this that do not match the current code digest are
        # pruned on write.
        STALE_AFTER = 60 * 60

        # Whether the disk cache is on; `HECKS_VERDICT_CACHE=off` disables it.
        #
        # @return [Boolean]
        def enabled? = ENV["HECKS_VERDICT_CACHE"] != "off"

        # The directory the verdict files live in.
        #
        # @return [String] an absolute path under `Hecks::CacheDir`
        def dir = Hecks::CacheDir.path("hecks_verdict_cache")

        # The file the current code's verdicts live in.
        #
        # @return [String] an absolute path
        def path = File.join(dir, "verdicts-#{code_digest}.json")

        # A digest of everything that decides a verdict: each file under
        # `lib/` outside `CONSUMER_TREES` (path and bytes), the Ruby and Hecks
        # versions and `FORMAT`.
        # Computed once per process, at first use, which is when the judging
        # code was loaded.
        #
        # @return [String] a hex SHA-256
        def code_digest = @code_digest ||= digest_of(File.expand_path("../../..", __dir__))

        # The digest `code_digest` reports, for any tree.
        #
        # @param lib [String] the directory whose files decide a verdict
        # @return [String] a hex SHA-256 over `FORMAT`, the versions and every
        #   file's relative path and bytes, in sorted order
        def digest_of(lib)
          state = Digest::SHA256.new
          state << "#{FORMAT}\0#{ruby_series}\0#{Hecks::VERSION}\0"
          judging_files(lib).each do |file|
            state << file.delete_prefix(lib) << "\0" << File.binread(file) << "\0"
          end
          state.hexdigest
        end

        # @param lib [String] the directory whose files decide a verdict
        # @return [Array<String>] every file under it outside `CONSUMER_TREES`, sorted
        def judging_files(lib)
          Dir.glob(File.join(lib, "**", "*"), File::FNM_DOTMATCH).sort.select do |file|
            File.file?(file) && !file.delete_prefix(lib).match?(CONSUMER_TREES)
          end
        end

        # Loads the stored verdicts, once per process; later calls return an
        # empty hash so a caller that resets its own memo re-judges for real.
        #
        # @return [Hash{String => Hash}] verdicts by chapter key; empty when
        #   the cache is off, absent, unreadable, corrupt or not private
        def seed
          return {} if @seeded

          @seeded = true
          return {} unless enabled?

          loaded = read
          entries.merge!(loaded)
          loaded.dup
        rescue StandardError
          {}
        end

        # Remembers a freshly judged chapter verdict for the next `flush`.
        #
        # @param key [String] the chapter's SHA-256 key
        # @param held [Hash] the verdict `MetaValidator.hold` returned
        # @return [void]
        def record(key, held)
          return unless enabled?

          entries[key] = held
          @dirty = true
          register_exit_flush
        end

        # Writes every known verdict when any was added since the last write.
        # Failure of any kind leaves the cache as it was.
        #
        # @return [void]
        def flush
          return unless @dirty && enabled?

          @dirty = false
          encoded = encode(entries)
          return unless decode(encoded) == entries

          write(JSON.generate({ "format" => FORMAT, "entries" => encoded }, max_nesting: false))
          prune
        rescue StandardError
          nil
        end

        # Forgets the process's own bookkeeping (not the files).
        #
        # @return [void]
        def reset!
          @seeded = false
          @dirty = false
          @entries = nil
          @code_digest = nil
        end

        # @return [Hash{String => Hash}] every verdict this process knows
        def entries = @entries ||= {}

        # Whether `file` and its directory belong to this user and nobody else
        # can write them.
        #
        # @param file [String] a path
        # @return [Boolean]
        def trusted?(file)
          [File.stat(file), File.stat(File.dirname(file))].all? do |stat|
            stat.owned? && stat.mode.nobits?(0o022)
          end
        end

        # @param entries [Object] a decoded `entries` value
        # @return [Boolean] whether it is a hash of chapter verdicts
        def well_formed?(entries)
          entries.is_a?(Hash) && entries.all? do |key, held|
            key.is_a?(String) && held.is_a?(Hash) && held[:refusals].is_a?(Array) &&
              (held[:refusals].any? || held[:declaration].is_a?(Hash))
          end
        end

        # Writes through a PID-suffixed temp file and an atomic rename, so a
        # concurrent reader never sees a torn file.
        #
        # @param text [String] the file body
        # @return [void]
        def write(text)
          file = path
          FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
          tmp = "#{file}.#{Process.pid}.tmp"
          File.binwrite(tmp, text)
          File.chmod(0o600, tmp)
          File.rename(tmp, file)
        end

        # Removes verdict files for other code digests once they are stale.
        #
        # @return [void]
        def prune
          keep = File.basename(path)
          Dir.glob(File.join(dir, "verdicts-*")).each do |file|
            next if File.basename(file) == keep || Time.now - File.mtime(file) < STALE_AFTER

            File.delete(file)
          rescue StandardError
            next
          end
        end

        # Registers the exit hook once per process.
        #
        # @return [void]
        def register_exit_flush
          return if @exit_registered

          @exit_registered = true
          at_exit { flush }
        end
      end
    end
  end
end
