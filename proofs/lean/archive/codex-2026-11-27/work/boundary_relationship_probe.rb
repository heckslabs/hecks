require "json"
require "sqlite3"
require "tmpdir"

# The finite program describes requested changes. The SQLite adapter gives
# `commit` its physical transaction contract; relation notation alone cannot.
class BoundaryMachine
  attr_reader :primary

  def initialize(path)
    @db = SQLite3::Database.new(path)
    @db.execute_batch(<<~SQL)
      CREATE TABLE records (id TEXT PRIMARY KEY, body TEXT NOT NULL);
      CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
      CREATE TABLE outbox (id INTEGER PRIMARY KEY, consumer TEXT NOT NULL,
        status TEXT NOT NULL, error TEXT);
    SQL
    @primary = "working"
    @staged = { record: nil, event: nil, consumer: nil }
  end

  def execute(program, fail_after_record: false)
    program.each do |op, value|
      case op
      when "stage_record" then @staged[:record] = value
      when "stage_event" then @staged[:event] = value
      when "stage_outbox" then @staged[:consumer] = value
      when "commit"
        begin
          @db.transaction do
            id, body = @staged.fetch(:record)
            @db.execute("INSERT INTO records(id, body) VALUES (?, ?)", [id, JSON.generate(body)])
            raise "disk full" if fail_after_record
            @db.execute("INSERT INTO events(name) VALUES (?)", [@staged.fetch(:event)])
            @db.execute("INSERT INTO outbox(consumer, status) VALUES (?, 'pending')", [@staged.fetch(:consumer)])
          end
          @primary = "success"
        rescue RuntimeError => e
          @primary = "fault"
          @fault = e.message
        end
      when "claim"
        @db.execute("UPDATE outbox SET status = 'claimed' WHERE status = 'pending'")
      when "refuse"
        @db.execute("UPDATE outbox SET status = 'refused', error = ? WHERE status = 'claimed'", [value])
      else raise "unknown operation #{op.inspect}"
      end
    end
  end

  def observation(id)
    body = @db.get_first_value("SELECT body FROM records WHERE id = ?", [id])
    { primary: @primary, fault: @fault, order: body && JSON.parse(body),
      events: @db.execute("SELECT name FROM events ORDER BY id").flatten,
      outbox: @db.execute("SELECT consumer, status, error FROM outbox ORDER BY id")
                 .map { |consumer, status, error| { consumer: consumer, status: status, error: error } } }
  end

  def close = @db.close
end

def order_program(id)
  [["stage_record", [id, { "number" => { "value" => id } }]],
   ["stage_event", "OrderPlaced"], ["stage_outbox", "policy:Shop::RecordOrder"], ["commit"]]
end

Dir.mktmpdir("crystal-boundary-relation-") do |dir|
  refused = BoundaryMachine.new(File.join(dir, "refused.db"))
  refused.execute(order_program("o-1"))
  refused.execute([["claim"], ["refuse", "Record refused — deliberate refusal"]])
  after_refusal = refused.observation("o-1")
  refused.close

  failed = BoundaryMachine.new(File.join(dir, "failed.db"))
  failed.execute(order_program("o-2"), fail_after_record: true)
  after_failure = failed.observation("o-2")
  failed.close

  # Reopen to ensure rollback survived the database close/reopen boundary.
  reopened = SQLite3::Database.new(File.join(dir, "failed.db"))
  reboot = { records: reopened.get_first_value("SELECT COUNT(*) FROM records"),
             events: reopened.get_first_value("SELECT COUNT(*) FROM events"),
             outbox: reopened.get_first_value("SELECT COUNT(*) FROM outbox") }
  reopened.close

  hecks = JSON.parse(File.read(File.join(__dir__, "../outputs/outbox-boundary.json")))
  hecks_refused = hecks.fetch("refused_reaction")
  reaction_match = after_refusal.fetch(:primary) == hecks_refused.fetch("command") &&
    after_refusal.fetch(:order) == hecks_refused.fetch("order") &&
    after_refusal.fetch(:events) == hecks_refused.fetch("events") &&
    after_refusal.fetch(:outbox) == hecks_refused.fetch("outbox_rows").map do |row|
      { consumer: row.fetch("consumer"), status: row.fetch("status"), error: row.fetch("error") }
    end
  rollback_match = after_failure == {
    primary: "fault", fault: "disk full", order: nil, events: [], outbox: []
  } && reboot == { records: 0, events: 0, outbox: 0 }
  hecks_sqlite = JSON.parse(File.read(File.join(__dir__, "../outputs/outbox-sqlite.json")))
  hecks_rollback_match = hecks_sqlite.fetch("failed_transaction") == {
    "error" => after_failure.fetch(:fault), "stored_order" => !after_failure.fetch(:order).nil?,
    "new_events" => after_failure.fetch(:events).length,
    "new_outbox_rows" => after_failure.fetch(:outbox).length
  }

  puts JSON.pretty_generate({ reaction_boundary_matches_hecks: reaction_match,
                              fault_rollback_matches_atomic_law: rollback_match,
                              fault_boundary_matches_hecks_sqlite: hecks_rollback_match,
                              reopened_database: reboot,
                              instruction_tags: %w[stage_record stage_event stage_outbox commit claim refuse] })
  exit(reaction_match && rollback_match && hecks_rollback_match ? 0 : 1)
end
