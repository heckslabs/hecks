require "digest"
require "fileutils"
require "json"
require_relative "../../cache_dir"
require_relative "../../version"
require_relative "verdict_cache/tagging"
require_relative "verdict_cache/prebuilt"
require_relative "verdict_cache/stored_pairs"
require_relative "verdict_cache/keeping"
require_relative "../../switches"

module Hecks
  module Bluebook
    module MetaValidator
      # Cross-process store of the meta-domain's bluebook verdicts, so a boot
      # judges only the bluebooks no earlier process has judged.
      #
      # Only bluebook verdicts live here; `Assembly.call` still runs every boot
      # and a miss judges as a cold process does. The file name carries a digest
      # of the judging code (`language_digest`); each entry is keyed by the bluebook
      # IR's SHA-256, so editing one domain re-judges only that bluebook.
      # The file is tagged JSON, never `Marshal`, read only from a private,
      # user-owned directory: a forged "no refusals" entry would skip validation.
      #
      #   VerdictCache.record(key, held)
      #   VerdictCache.flush  # also runs at process exit
      module VerdictCache
        extend Tagging
        extend Prebuilt
        extend StoredPairs
        extend Keeping

        module_function

        # Bumped when the encoding or the entry shape changes.
        FORMAT = 1

        # The subtrees of `lib/` that read the language and never judge it: they
        # project, serve or deploy from a bluebook, and nothing the judge runs
        # calls into them. An edit there leaves every verdict as it was, so
        # their files stay out of the key. Paths are relative to `lib/hecks`.
        CONSUMER_TREES = %r{\A/hecks/(?:bench|cli|codemod|deploy|doc|adapters/driving|fuzzing|projections|
                            quality_control|release)(?:/|\.rb\z)}x

        # The subtrees of `lib/` that are domains built in the language, not the language: each
        # holds bluebooks and the adapters behind their ports, and `require "hecks"` loads none of
        # their Ruby. The grammar table is built from the grammar files by code outside these
        # trees, and a verdict is a function of that code and the bluebook's own IR, so an edit here
        # leaves both as they were (`language_digest`). Paths are relative to `lib/hecks`;
        # `spec/syntax_boot_key_spec.rb` fails if the table is built after any of these trees' Ruby
        # is loaded, or if describing the Hecks domain loads Ruby from them that is not an adapter.
        APPLIED_TREES = %r{\A/hecks/(?:hecks|tickets|pipeline|pipeline_board|gate|questions|coder|
                           catcher|ci_pipeline|ci_speed|ci_workflows|fixer|site|sme|tenancy|
                           rails_app)(?:/|\.rb\z)}x

        # A file of other code that has not been read or written for this long is pruned on write.
        # Reading marks a file as used, so a checkout that only reads keeps its file.
        STALE_AFTER = 24 * 60 * 60

        # The most verdict files kept in all, the current code's among them.
        MAX_DIGESTS = 8

        # Whether the disk cache is on; `HECKS_VERDICT_CACHE=off` disables it.
        #
        # @return [Boolean]
        def enabled? = Hecks::Switches.verdict_cache?

        # The directory the verdict files live in.
        #
        # @return [String] an absolute path under `Hecks::CacheDir`
        def dir = Hecks::CacheDir.path("hecks_verdict_cache")

        # The file the current code's verdicts live in.
        #
        # @return [String] an absolute path
        def path = File.join(dir, "verdicts-#{language_digest}.json")

        # A digest of everything that decides a verdict: each file under
        # `lib/` outside `CONSUMER_TREES` (path and bytes), the Ruby and Hecks
        # versions and `FORMAT`.
        # Computed once per process, at first use, which is when the judging
        # code was loaded.
        #
        # @return [String] a hex SHA-256
        def code_digest = @code_digest ||= digest_of(lib_root)

        # A digest of the language alone: `code_digest` without the `APPLIED_TREES`, so editing a
        # domain built in the language (a bluebook or an adapter under them) keeps the grammar
        # table a process built, which is the longest step of a cold boot.
        # Computed once per process.
        #
        # @return [String] a hex SHA-256
        def language_digest = @language_digest ||= digest_of(lib_root, skip: [CONSUMER_TREES, APPLIED_TREES])

        # The digest `code_digest` reports, for any tree.
        #
        # @param lib [String] the directory whose files decide a verdict
        # @param skip [Array<Regexp>] the subtrees, as paths below `lib`, that stay out of it
        # @return [String] a hex SHA-256 over `FORMAT`, the versions and every
        #   file's relative path and bytes, in sorted order
        def digest_of(lib, skip: [CONSUMER_TREES])
          state = Digest::SHA256.new
          state << "#{FORMAT}\0#{ruby_series}\0#{Hecks::VERSION}\0"
          judging_files(lib, skip: skip).each do |file|
            state << file.delete_prefix(lib) << "\0" << File.binread(file) << "\0"
          end
          state.hexdigest
        end

        # @param lib [String] the directory whose files decide a verdict
        # @param skip [Array<Regexp>] the subtrees, as paths below `lib`, that stay out
        # @return [Array<String>] every file under it outside `skip`, sorted
        def judging_files(lib, skip: [CONSUMER_TREES])
          Dir.glob(File.join(lib, "**", "*"), File::FNM_DOTMATCH).sort.select do |file|
            File.file?(file) && skip.none? { |tree| file.delete_prefix(lib).match?(tree) }
          end
        end

        # @return [String] the directory of the gem's Ruby, whose files the digests cover
        def lib_root = File.expand_path("../../..", __dir__)

        # Loads the stored verdicts, once per process; later calls return an
        # empty hash so a caller that resets its own memo re-judges for real.
        #
        # @return [Hash{String => Hash}] verdicts by bluebook key; empty when
        #   the cache is off, absent, unreadable, corrupt or not private
        def seed
          return {} if @seeded

          @seeded = true
          return {} unless enabled?

          loaded = read.tap { |held| @loaded = held.size }
          entries.merge!(loaded)
          loaded.dup
        rescue StandardError
          {}
        end

        # Remembers a freshly judged bluebook verdict for the next `flush`.
        #
        # @param key [String] the bluebook's SHA-256 key
        # @param held [Hash] the verdict `MetaValidator.hold` returned
        # @return [void]
        def record(key, held)
          return unless enabled?

          entries[key] = held
          return unless encodable?(held)

          @dirty = true
          register_exit_flush
        end

        # How many bluebooks this process judged because the cache did not hold their verdict. A
        # process that judged any booted cold; one that judged none booted warm.
        #
        # @return [Integer]
        def misses = [entries.size - @loaded.to_i, 0].max

        # Writes every known verdict when any was added since the last write.
        # Failure of any kind leaves the cache as it was.
        #
        # @return [void]
        def flush
          return unless @dirty && enabled?

          @dirty = false
          pairs = stored_pairs
          return unless pairs

          keep(pairs)
          prune
        rescue StandardError
          nil
        end

        # Forgets the process's own bookkeeping (not the files).
        #
        # @return [void]
        def reset!
          @seeded = @dirty = false
          @loaded = nil
          @entries = nil
          @read_pairs = nil
          @code_digest = nil
          @language_digest = nil
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
        # @return [Boolean] whether it is a hash of bluebook verdicts
        def well_formed?(entries)
          entries.is_a?(Hash) && entries.all? do |key, held|
            key.is_a?(String) && held.is_a?(Hash) && held[:refusals].is_a?(Array) &&
              (held[:refusals].any? || held[:declaration].is_a?(Hash))
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
