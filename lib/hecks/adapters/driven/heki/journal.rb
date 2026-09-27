require_relative "../../../ports/persistence/append_only"

module Hecks
  module Adapters
    class Heki
      # The append-only journal beside the snapshot: one JSON line per
      # entry, fsynced on append, replayed over the snapshot on read.
      module Journal
        # Reads the whole journal back in append order, for `AppendOnly#recover!` to replay.
        #
        # @return [Array<Ports::Persistence::Entry>] every journalled entry, state decoded
        #   through the state codec; `[]` when the journal file does not exist or is empty
        # @raise [Malformed] if a journal line is not valid JSON
        def entries
          return [] unless File.exist?(@journal_path)

          File.readlines(@journal_path, chomp: true).reject(&:empty?).map do |line|
            value = JSON.parse(line)
            state = Ports::Persistence::StateCodec.decode(@aggregate, value["state"])
            Ports::Persistence::Entry.new(operation: value.fetch("operation"), id: value.fetch("id"), state: state,
                                          mirrors: value["mirrors"])
          end
        end

        # Folds the journal into the snapshot and truncates it. Opt-in; never run after a save.
        #
        # This discards the history `entries` returns, which projections and `bin/history`
        # read in full, so use it only on an aggregate nothing projects from.
        #
        # The snapshot is written durably before the journal is truncated; a crash between
        # the two leaves redundant lines whose replay is idempotent.
        #
        # @return [void]
        # @raise [Malformed] if the snapshot or journal file is corrupt
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

          # `truncate(0)` is atomic; the fsync makes it durable before returning.
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
          encoded = Ports::Persistence::StateCodec.encode(@aggregate, state)
          line = "#{JSON.generate(operation: operation, id: id.to_s, state: encoded, mirrors: @entry_mirrors)}\n"

          # One write, so a concurrent append cannot land in the middle of this line.
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
