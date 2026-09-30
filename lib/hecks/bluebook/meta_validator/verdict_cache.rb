require "digest"
require "fileutils"
require "json"
require_relative "../../cache_dir"
require_relative "../../version"

module Hecks
  module Bluebook
    module MetaValidator
      # Cross-process store of the meta-domain's chapter verdicts, so a boot
      # judges only the chapters no earlier process has judged.
      #
      # Only `MetaValidator.call`'s chapter verdicts (`{refusals: [...]}` or
      # `{refusals: [], declaration: Hash}`) live here. `Assembly.call` still
      # runs on every boot, and a miss judges exactly as a cold process does.
      #
      # The file name carries a digest of the judging code (every file under
      # `lib/`, plus the Ruby and Hecks versions and `FORMAT`), so an edit to
      # any validator, builder or grammar file selects a different file. Each
      # entry inside is keyed by the SHA-256 of the chapter's own IR.
      #
      # The file is JSON with symbols and hash pairs tagged, never `Marshal`,
      # so reading it cannot run code. It is still read only from a private,
      # user-owned directory, since a forged "no refusals" entry would skip
      # validation.
      #
      #   VerdictCache.seed   # => { "<chapter key>" => { refusals: [], declaration: {...} } }
      #   VerdictCache.record(key, held)
      #   VerdictCache.flush  # writes new entries (also runs at process exit)
      module VerdictCache
        module_function

        # Bumped when the encoding or the entry shape changes.
        FORMAT = 1

        # Files older than this that do not match the current code digest are
        # pruned on write.
        STALE_AFTER = 24 * 60 * 60

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
        # `lib/` (path and bytes), the Ruby and Hecks versions and `FORMAT`.
        # Computed once per process, at first use, which is when the judging
        # code was loaded.
        #
        # @return [String] a hex SHA-256
        def code_digest
          @code_digest ||= begin
            lib   = File.expand_path("../../..", __dir__)
            state = Digest::SHA256.new
            state << "#{FORMAT}\0#{RUBY_VERSION}\0#{Hecks::VERSION}\0"
            Dir.glob(File.join(lib, "**", "*"), File::FNM_DOTMATCH).sort.each do |file|
              next unless File.file?(file)

              state << file.delete_prefix(lib) << "\0" << File.binread(file) << "\0"
            end
            state.hexdigest
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

        # Reads and decodes the current code's file.
        #
        # @return [Hash{String => Hash}] entries, or `{}` on any problem
        def read
          file = path
          return {} unless File.file?(file) && trusted?(file)

          doc = JSON.parse(File.binread(file), max_nesting: false)
          return {} unless doc.is_a?(Hash) && doc["format"] == FORMAT

          decoded = decode(doc["entries"])
          well_formed?(decoded) ? decoded : {}
        rescue StandardError
          {}
        end

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

        # Encodes plain data as JSON-safe data, tagging what JSON would lose:
        # a symbol is `{"$s" => name}`, a hash is `{"$h" => [[key, value], ...]}`
        # (pair order is hash order).
        #
        # @param obj [Object] Hash, Array, String, Symbol, Integer, nil, true or false
        # @return [Object] the tagged form
        # @raise [ArgumentError] for any other class
        def encode(obj)
          case obj
          when Symbol then { "$s" => obj.to_s }
          when Hash then { "$h" => obj.map { |key, value| [encode(key), encode(value)] } }
          when Array then obj.map { |item| encode(item) }
          when String
            raise ArgumentError, "unencodable string" unless obj.valid_encoding? && (obj.ascii_only? || obj.encoding == Encoding::UTF_8)

            obj
          when Integer, nil, true, false then obj
          else raise ArgumentError, "unencodable #{obj.class}"
          end
        end

        # The inverse of `encode`.
        #
        # @param obj [Object] the tagged form
        # @return [Object] the original data
        def decode(obj)
          case obj
          when Array then obj.map { |item| decode(item) }
          when Hash
            if obj.size == 1 && obj.key?("$s") then obj["$s"].to_sym
            elsif obj.size == 1 && obj.key?("$h") then obj["$h"].to_h { |key, value| [decode(key), decode(value)] }
            else raise ArgumentError, "untagged hash"
            end
          else obj
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
