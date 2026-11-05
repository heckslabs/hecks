# frozen_string_literal: true

require "json"
require "fileutils"
require "pg"
require_relative "fenced_owner"
require_relative "first_era_hold"
require_relative "era_registry_loading"

# A disposable ledger domain for the mint plan specs: a directory holding the bluebook, the world
# that names a scratch database, and the translation edges a spec writes. Era 1 is held from the
# first shape; the bluebook is then rewritten to the shape a mint would lead to.
module MintPlanShop
  include FirstEraHold

  OWNER = <<~RUBY
    aggregate "Owner" do
      identified_by :title
      attribute :title, Title
      value_object("Title") { attribute :label, String }
    end
  RUBY

  NOTE = %(attribute :note, Note, optional: true\n    value_object("Note") { attribute :text, String })

  # The ledger's bluebook: `Acct` holds a cost whose cents are `type`, optionally a reference to
  # `Owner`, and a note when `note` is set.
  def source(type: "Integer", note: false, reference: false)
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        #{OWNER}
        aggregate "Acct" do
          identified_by :kind
          attribute :cost, Money
          attribute :kind, Kind
          #{%(reference_to "Owner") if reference}
          #{NOTE if note}
          value_object("Money") { attribute :cents, #{type} }
          value_object("Kind") { attribute :label, String }
        end
      end
    BLUEBOOK
  end

  # Writes the domain into `dir` with `text` as its bluebook.
  def write_domain(dir, text, url:, world_lines: "mint_eras true")
    FileUtils.mkdir_p(File.join(dir, "bluebook"))
    File.write(File.join(dir, "bluebook/ledger.bluebook"), text)
    File.write(File.join(dir, "bluebook/ledger.hecksagon"),
               %(Hecks.hecksagon "Ledger" do\n  persisted_by "Postgres"\n  revisions true\nend\n))
    File.write(File.join(dir, "bluebook/ledger.world"), world(url, world_lines))
  end

  def world(url, lines)
    %(Hecks.world "Ledger" do\n  persisted_by("Postgres") do\n    database "#{url}"\n    #{lines}\n  end\nend\n)
  end

  # Holds era 1 from `first`, then rewrites the bluebook to `current`.
  def hold_then_change(dir, first, current, url:)
    write_domain(dir, first, url: url)
    hold_domain_eras!(directory: File.join(dir, "bluebook"), url: url)
    File.write(File.join(dir, "bluebook/ledger.bluebook"), current)
  end

  def label_of(text) = Hecks::Runtime::StorageShape.mint_label(load_registry(text).bluebooks.fetch("Ledger"))

  # Writes an edge from the label of `from` to the label of `to`, with `body` as its rules.
  def write_edge(dir, from, to, body: "", name: "edge")
    FileUtils.mkdir_p(File.join(dir, "bluebook/translations"))
    text = %(Hecks.data_translation("Ledger", from: "#{label_of(from)}", to: "#{label_of(to)}") do\n#{body}\nend\n)
    File.write(File.join(dir, "bluebook/translations/#{name}.bluebook"), text)
  end

  # The plan for `dir`, as a hash.
  def plan_of(dir, **args)
    text = Hecks::Adapters::JournalStore.new.mint_plan(domain: File.join(dir, "bluebook"), **args)[:text]
    JSON.parse(text, symbolize_names: true)
  end

  def guard(plan, name) = plan[:guards].find { |entry| entry[:guard] == name }

  # Appends a journal row, as a write to the ledger would.
  def append_row(url, aggregate, id)
    db = PG.connect(url)
    db.exec_params("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, state) VALUES (1, $1, $2, '{}')",
                   [aggregate, id])
  ensure
    db&.close
  end

  # The count of rows in every table and the write counters Postgres keeps for each, read
  # again until two reads agree, so counters still in flight have landed.
  def database_state(url)
    previous = nil
    100.times do
      current = read_state(url)
      return current if current == previous

      previous = current
    end
    previous
  end

  def read_state(url)
    db = PG.connect(url)
    tables = db.exec("SELECT relname FROM pg_stat_user_tables ORDER BY 1").map { |row| row["relname"] }
    counts = tables.to_h { |table| [table, db.exec("SELECT count(*) AS n FROM #{db.quote_ident(table)}")[0]["n"]] }
    [counts, writes(db)]
  ensure
    db&.close
  end

  def writes(db)
    db.exec("SELECT relname, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_user_tables ORDER BY 1").map(&:to_a)
  end
end
