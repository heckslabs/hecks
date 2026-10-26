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
        # This discards the history `entries` returns, which projections and `hecks history`
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

        # Reads the chain heads the ledger sealed beside this journal, oldest first.
        #
        # A Heki journal has no sequence and is emptied by compaction, so `through:` counts the
        # entries sealed since the first seal, across compactions.
        #
        # @return [Array<Hash>] `through:`, `head:` and `previous:` (the genesis digest first)
        # @raise [Malformed] if a line of the anchors file is not valid JSON
        def ledger_anchors
          return [] unless File.exist?(anchors_path)

          lines = File.readlines(anchors_path, chomp: true).reject(&:empty?)
          lines.map { |line| anchor_from(JSON.parse(line)) }.sort_by { |anchor| anchor[:through] }
        rescue JSON::ParserError => e
          raise Malformed, "#{anchors_path}: json error: #{e.message}"
        end

        # Seals a chain head beside this journal, one line, fsynced. Sealing the same point twice
        # with the same head changes nothing; a different head for a sealed point is refused.
        #
        # @param through [Integer] how many entries the seals cover in all
        # @param head [String] the chain digest at `through`
        # @param previous [String] the head of the seal before this one
        # @return [void]
        # @raise [Runtime::WiringError] if the point is already sealed with another head
        def record_ledger_anchor(through:, head:, previous:)
          sealed = ledger_anchors.find { |anchor| anchor[:through] == through }
          if sealed
            return if sealed[:head] == head

            raise Runtime::WiringError, "#{anchors_path} is already sealed through #{through} with another head"
          end

          File.open(anchors_path, "ab") do |file|
            file.write("#{JSON.generate(through: through, head: head, previous: previous)}\n")
            file.flush
            file.fsync
          end
        end

        private

        def anchors_path = "#{@path}.anchors"

        def anchor_from(value)
          { through: value.fetch("through"), head: value.fetch("head"), previous: value.fetch("previous") }
        end

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

          File.foreach(@journal_path) { |line| replay_line(records, JSON.parse(line)) }
          records
        rescue JSON::ParserError => e
          raise Malformed, "#{@journal_path}: json error: #{e.message}"
        end

        def replay_line(records, entry)
          id = entry.fetch("id")

          case entry.fetch("operation")
          when "save"   then records[id] = entry.fetch("state")
          when "delete" then records.delete(id)
          else raise Malformed, "#{@journal_path}: unknown journal operation #{entry.fetch("operation").inspect}"
          end
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
