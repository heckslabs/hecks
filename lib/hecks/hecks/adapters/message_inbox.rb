# frozen_string_literal: true

require "json"
require "sqlite3"

module Hecks
  module Adapters
    # A session's inbox, read from the journal (the `events` table of `agent_run.db`) with read-only
    # SQL. It boots no domain and writes nothing: a `MessageSent` row is addressed to a session id,
    # a work item id or `all`, and a `MessageAnswered` row is addressed to the session that sent the
    # message it answers. It reads and judges nothing else: the text of a message is information,
    # printed as it was sent, and nothing here acts on it.
    #
    # A baseline file keeps the id of the last journal row delivered, so a monitor that stops and
    # starts again, or a second monitor, resumes after it and a message sent in the gap is not lost.
    class MessageInbox
      # Where the journal lives unless a setting names another database.
      DATABASE = "~/.claude/hecks-dev/agent_run.db"

      # The recipient every session hears, which the red flag announcements use.
      EVERYONE = "all"

      # @param session [String] the session's id
      # @param work [Array<String>] the ids of the work items the session is on
      # @param database [String, nil] the journal database (default `DATABASE`)
      def initialize(session:, work: [], database: nil)
        @session = session.to_s
        @targets = [@session, *Array(work).map(&:to_s), EVERYONE]
        @database = File.expand_path(database || DATABASE)
      end

      # @param after [Integer] the id of the last journal row already delivered
      # @return [Array<Hash>] the rows to deliver, oldest first, each with `id`, `message`, `kind`,
      #   `from` and `text`
      def deliveries(after: 0)
        with_journal do |db|
          sent = rows(db, "MessageSent", after).select { |row| @targets.include?(row[:recipient]) }
          read = reads(db)
          answers = answers(db, after)
          (sent.reject { |row| read.include?(row[:message]) } + answers).sort_by { |row| row[:id] }
        end
      end

      # @return [Array<Hash>] every message sent and not read yet, for a coordinator: `message`,
      #   `recipient`, `from`, `text`, oldest first
      def unread
        with_journal do |db|
          read = reads(db, any_reader: true)
          rows(db, "MessageSent", 0).reject { |row| read.include?(row[:message]) }
        end
      end

      # Prints each new delivery as one line and moves the baseline after it.
      #
      # @param baseline [String] the file that holds the last delivered journal row id
      # @param out [#puts] where the lines go
      # @return [Integer] how many lines were printed
      def deliver(baseline:, out: $stdout)
        last = File.file?(baseline) ? File.read(baseline).to_i : 0
        rows = deliveries(after: last)
        rows.each do |row|
          out.puts(line(row))
          File.write(baseline, row[:id].to_s)
        end
        rows.size
      end

      private

      def line(row)
        "[message #{row[:message]}] #{row[:kind]} from #{row[:from]}: #{row[:text]}"
      end

      def with_journal
        db = SQLite3::Database.new(@database, readonly: true)
        yield db
      rescue SQLite3::CantOpenException, SQLite3::SQLException
        []
      ensure
        db&.close
      end

      # The journal rows named `name` after row `after`, oldest first: row id, message id, payload.
      def journal(db, name, after)
        db.execute("SELECT id, aggregate_id, payload FROM events WHERE name = ? AND id > ? ORDER BY id", [name, after])
          .map { |id, message, json| [id, message.to_s, JSON.parse(json.to_s)] }
      end

      def rows(db, name, after)
        journal(db, name, after).map { |id, message, payload| sent(id, message, payload) }
      end

      def sent(id, message, payload)
        { id: id, message: message, recipient: word(payload, "recipient"), kind: word(payload, "kind"),
          from: word(payload, "sender"), text: word(payload, "text") }
      end

      # The messages a reader read: this session's reads, or any reader's for a coordinator.
      def reads(db, any_reader: false)
        journal(db, "MessageRead", 0).filter_map do |_id, message, payload|
          message if any_reader || word(payload, "reader") == @session
        end
      end

      def answers(db, after)
        mine = rows(db, "MessageSent", 0).select { |row| row[:from] == @session }.map { |row| row[:message] }
        journal(db, "MessageAnswered", after).select { |_id, message, _payload| mine.include?(message) }
                                             .map { |id, message, payload| answered(id, message, payload) }
      end

      def answered(id, message, payload)
        { id: id, message: message, kind: "answer", from: "answerer", text: word(payload, "text") }
      end

      def word(payload, key)
        value = payload[key]
        (value.is_a?(Hash) ? value["value"] : value).to_s
      end
    end
  end
end
