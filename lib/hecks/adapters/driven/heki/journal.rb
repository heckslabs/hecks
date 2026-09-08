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

        private

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
