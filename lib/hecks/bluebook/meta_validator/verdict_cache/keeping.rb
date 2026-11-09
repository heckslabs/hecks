require "fileutils"
require "json"

module Hecks
  module Bluebook
    module MetaValidator
      module VerdictCache
        # How the verdict files are kept on disk: written under a lock that merges what another
        # process added, marked as used when read, and pruned by use, never by when they were last
        # rewritten (a file that is only ever read is not rewritten, and is still in use).
        module Keeping
          # How many times the lock is tried, a tenth of a second apart, before the file is written
          # without it; the rename is atomic, so the cost of skipping the merge is a lost entry.
          LOCK_TRIES = 20

          # How long a temp file from a writer that died is left before it is removed.
          TEMP_KEPT = 60 * 60

          # Writes every pair the file should hold, adding the pairs another process stored since
          # this one read the file.
          #
          # @param pairs [Array<Array>] the encoded `[key, verdict]` pairs this process holds
          # @return [void]
          def keep(pairs)
            locked do |held|
              merged = held ? pairs + other_pairs(pairs) : pairs
              write(JSON.generate({ "format" => FORMAT, "entries" => { "$h" => merged } }, max_nesting: false))
            end
          end

          # Marks a verdict file as used now, so the pruning of other code's files sees it.
          #
          # @param file [String] a path
          # @return [void]
          def touch_used(file)
            File.utime(nil, nil, file)
          rescue SystemCallError
            nil
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

          # Removes the files of other code digests that have not been used for `STALE_AFTER`, keeps
          # no more than `MAX_DIGESTS` files in all, and clears what a dead writer left beside them.
          #
          # @param now [Time] the time to judge by
          # @return [void]
          def prune(now: Time.now)
            old, recent = other_files.partition { |file| now - used_at(file, now) >= STALE_AFTER }
            newest = recent.sort_by { |file| -used_at(file, now).to_f }
            (old + newest.drop(MAX_DIGESTS - 1)).each { |file| delete_quietly(file) }
            sweep_leftovers(now)
          end

          private

          def other_files = Dir.glob(File.join(dir, "verdicts-*.json")).reject { |file| file == path }

          def locked
            FileUtils.mkdir_p(dir, mode: 0o700)
            File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
              yield acquired?(lock)
            end
          end

          def acquired?(lock)
            LOCK_TRIES.times do
              return true if lock.flock(File::LOCK_EX | File::LOCK_NB)

              sleep 0.1
            end
            false
          end

          # The pairs the file holds now that this process does not, or none when it is not a file
          # this user wrote in the right shape.
          def other_pairs(pairs)
            known = pairs.to_set(&:first)
            stored_now.reject { |pair| known.include?(pair.first) }
          end

          def stored_now
            file = path
            return [] unless File.file?(file) && trusted?(file)

            doc = JSON.parse(File.binread(file), max_nesting: false)
            return [] unless doc.is_a?(Hash) && doc["format"] == FORMAT && well_formed?(decode(doc["entries"]))

            doc["entries"]["$h"]
          rescue StandardError
            []
          end

          def sweep_leftovers(now)
            Dir.glob(File.join(dir, "verdicts-*.json.*")).each do |file|
              delete_quietly(file) if leftover?(file, now)
            end
          end

          def leftover?(file, now)
            return now - used_at(file, now) > TEMP_KEPT if file.end_with?(".tmp")

            file.end_with?(".lock") && !File.exist?(file.delete_suffix(".lock"))
          end

          def used_at(file, now)
            File.mtime(file)
          rescue SystemCallError
            now
          end

          def delete_quietly(file)
            File.delete(file)
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
