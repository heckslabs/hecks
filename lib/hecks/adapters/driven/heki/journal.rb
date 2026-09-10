require_relative "../../../ports/persistence/append_only"

module Hecks
  module Adapters
    class Heki
      # The append-only journal beside the snapshot: one JSON line per
      # entry, fsynced on append, replayed over the snapshot on read.
      module Journal
        def entries
          return [] unless File.exist?(@journal_path)

          File.readlines(@journal_path, chomp: true).reject(&:empty?).map do |line|
            value = JSON.parse(line)
            state = value["state"]&.transform_keys(&:to_sym)
            Ports::Persistence::Entry.new(operation: value.fetch("operation"), id: value.fetch("id"), state: state,
                                          mirrors: value["mirrors"])
          end
        end

        # An EXPLICIT, opt-in maintenance operation — never run
        # automatically after an ordinary save/delete. Heki's journal is
        # not a disposable write-ahead log: it is this adapter's own
        # answer to `entries`, and `entries` is a real port contract
        # (`Ports::Persistence::AppendOnly`'s own required-methods list)
        # read in full, forever, by `Ports::Projection::Worker#catch_up!`
        # and `Registry#projection_current?` to catch a projection up to
        # its authoritative source, and by `bin/history` to show "every
        # journal entry a domain's append-only adapters hold" — the same
        # contract Postgres/Sqlite/D1 uphold by way of a journal TABLE
        # that is never pruned. A real example (`examples/banking`,
        # `persisted_by("Heki")` + `projected_by("SqliteProjection")`)
        # depends on this today. Compacting throws that full history away
        # for whatever happened before the call — correct only for an
        # aggregate nothing ever projects from; callers (`bin/
        # heki_compact`) are responsible for confirming that first.
        #
        # Crash-safety ordering: `write` below is the exact same
        # temp-file, fsync, atomic-rename sequence `save`/`delete`
        # already use — the snapshot it produces is confirmed durably on
        # disk before this method ever touches the journal. Only once
        # that succeeds does `truncate_journal!` run. A crash between the
        # two leaves old (now fully redundant) journal lines in place;
        # replaying them again over the fresh snapshot on the next boot
        # is idempotent — the same value gets set again, never a wrong
        # one — so nothing is lost, just a little wasted replay work
        # once. A crash before `write` completes leaves the journal
        # fully intact and the prior snapshot untouched, exactly today's
        # existing crash-recovery guarantee.
        def compact!
          with_lock do
            current = replay_journal(read_snapshot)
            write(current)
            truncate_journal!
            @store = current
          end
        end

        private

        def truncate_journal!
          return unless File.exist?(@journal_path)

          # A single `truncate(0)` syscall on an already-open file
          # descriptor — the file's length changes atomically at the
          # filesystem level, so there is no "half truncated" state to
          # observe even under a crash mid-call. `fsync` below makes
          # that change durable before this method returns; without it
          # a crash could still leave the old (harmless-to-replay)
          # content on disk after a normal return, which is fine per
          # the crash-safety note above, but the durable case is the
          # one actually worth returning success for.
          File.open(@journal_path, "r+b") do |file|
            file.truncate(0)
            file.flush
            file.fsync
          end
        end

        def replay_journal(records)
          return records unless File.exist?(@journal_path)

          File.foreach(@journal_path) do |line|
            entry = JSON.parse(line)
            id    = entry.fetch("id")

            case entry.fetch("operation")
            when "save"   then records[id] = entry.fetch("state")
            when "delete" then records.delete(id)
            else raise Malformed, "#{@journal_path}: unknown journal operation #{entry.fetch('operation').inspect}"
            end
          end
          records
        rescue JSON::ParserError => e
          raise Malformed, "#{@journal_path}: json error: #{e.message}"
        end

        def append_entry(operation, id, state)
          line = "#{JSON.generate(operation: operation, id: id.to_s, state: state, mirrors: @entry_mirrors)}\n"

          # One write, not JSON-then-newline as two: two concurrent
          # appends can only interleave *between* writes, never inside
          # one, so this line can't come out split by another process's
          # line landing in the middle of it.
          File.open(@journal_path, "ab") do |journal|
            journal.write(line)
            journal.flush
            journal.fsync
          end
        end
      end
    end
  end
end
