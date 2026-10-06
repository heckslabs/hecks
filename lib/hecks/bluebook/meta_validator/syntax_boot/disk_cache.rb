module Hecks
  module Bluebook
    module MetaValidator
      module SyntaxBoot
        # The grammar table's memo keys and its cross-process copy on disk.
        module DiskCache
          # `equal?`, not `==` — chapter identity, not value equality, is the
          # fact this cache key tracks.
          def same_chapters?(cached, current)
            cached.size == current.size &&
              cached.zip(current).all? do |(cached_name, cached_chapter), (name, chapter)|
                cached_name == name && cached_chapter.equal?(chapter)
              end
          end

          # Cross-process persistence for the same build `call` already memoizes
          # in-process, keyed by chapter name (not identity, which means nothing
          # across processes) plus a content hash of every grammar file `boot`
          # can read from — so a source edit anywhere in that set misses the
          # cache rather than silently serving a stale table.
          def cache_dir = Hecks::CacheDir.path("hecks_syntax_boot_cache")

          def disk_cache_enabled? = ENV["HECKS_SYNTAX_BOOT_CACHE"] != "off"

          # Fails toward a real boot, never toward a wrong table: a missing
          # file, a corrupt blob, or a permission error just misses the cache.
          def read_disk_cache(chapters)
            return nil unless disk_cache_enabled?

            path = disk_cache_path(chapters)
            return nil unless File.exist?(path)

            Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad -- own process-local cache, never external input
          rescue StandardError
            nil
          end

          # Writes to a PID-suffixed temp file and renames it into place, so a
          # concurrent writer's rename can only overwrite with identical
          # content, never leave a torn file for a concurrent reader.
          def write_disk_cache(chapters, result)
            return unless disk_cache_enabled?

            path = disk_cache_path(chapters)
            FileUtils.mkdir_p(cache_dir)
            tmp_path = "#{path}.#{Process.pid}.tmp"
            File.binwrite(tmp_path, Marshal.dump(result))
            File.rename(tmp_path, path)
          rescue StandardError
            nil
          end

          def disk_cache_path(chapters)
            File.join(cache_dir, "#{disk_cache_key(chapters)}.marshal")
          end

          def disk_cache_key(chapters)
            names = chapters.map { |name, _chapter| name }
            Digest::SHA256.hexdigest("#{names.join(",")}:#{grammar_content_digest}:#{VerdictCache.code_digest}")
          end

          # The key also carries `VerdictCache.code_digest` (all of `lib/`), so an
          # edit to Ruby that builds or judges the grammar misses too.
          #
          # Covers every chapter's grammar files, not just the core ones —
          # coarser than strictly necessary, but under-covering this set would
          # let a stale table survive a real grammar edit.
          def grammar_content_digest
            files = (MetaValidator::GRAMMAR_FILES + MetaValidator::WORLD_GRAMMAR + MetaValidator::HECKSAGON_GRAMMAR +
                      Dir.glob(File.join(MetaValidator::ATTACHED_GRAMMAR_DIR, "*.bluebook"))).sort
            Digest::SHA256.hexdigest(files.map { |file| File.read(file) }.join("\0"))
          end
        end
      end
    end
  end
end
