require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# THE MULTI-BLUEBOOK / POSTGRESERA GAP, FOUND LIVE against a real,
# private project (children-of-the-light) attaching a vendored chapter
# via `uses_embryonaut_bluebook`: PostgresEra's own era-1 self-mint for
# the SECOND bluebook loaded into a registry wrote the FIRST (target)
# bluebook's own source text into `hecks_eras.held_text` — not the
# second bluebook's own. The very next boot re-derived the second
# bluebook's REAL shape, found it didn't match the (wrongly) stored
# text, and refused to boot toward a scaffold for drift that never
# actually happened. 100% reproducible, not a race — confirmed twice in
# a row against real Postgres before this spec existed.
#
# ROOT CAUSE — `EraCheck.source_text_for` (era_check.rb): its own
# single-file-directory fallback only excluded a bluebook known to
# `Framework.members` (a `uses_framework` member, e.g. Governance) from
# being handed the ONE OTHER file that happens to sit in the domain's
# own directory. A `uses_embryonaut_bluebook`-vendored chapter has no
# equivalent registry to check against — its real source lives under
# `vendor/embryonaut_bluebooks/<name>/bluebook/`, entirely outside the
# domain's own directory — so the guard let it fall straight through
# and hand back the TARGET domain's own single file as if it were the
# vendored bluebook's own source. Fixed by teaching `source_text_for`
# to ask the registry itself whether any hecksagon recorded a
# `uses_embryonaut_bluebook` call whose name Pascal-cases to this
# bluebook's own name, and if so, read its real source straight from
# the vendored package's own directory — the same path
# `EmbryonautBluebook.load!` itself already resolves from.
#
# NEVER EXERCISED TOGETHER BEFORE THIS SPEC — confirmed by reading the
# existing suite: `spec/runtime/era_check_spec.rb` only ever boots a
# SINGLE bluebook (Memory-backed, no era system in play at all — "holds
# nothing for an adapter that has no eras"); every `uses_framework`/
# `uses_embryonaut_bluebook` spec (`tenant_isolation_spec.rb`,
# `spec/act_as_spec.rb`, etc.) boots Memory or a bare `uses_framework
# "Governance"` — which is a `Framework.members` name, so it never took
# the single-file fallback's WRONG branch — and every real PostgresEra
# era-minting spec (`spec/adapters/driven/postgres_era_spec.rb`,
# `spec/adapters/driven/postgres_era/lineage_spec.rb`) boots exactly one
# bluebook at a time, directly through `LineageManager.check!`, never
# through a registry holding a second, attached one. Multi-bluebook +
# PostgresEra self-minting was a genuine, unexercised seam.
RSpec.describe "PostgresEra era-1 minting for a second bluebook in a multi-bluebook registry", :io do
  VENDORED_BLUEBOOK_DB = "hecks_era_vendored_bluebook_spec".freeze

  def owner_url = FencedOwner.url(VENDORED_BLUEBOOK_DB)

  def target_bluebook
    <<~BLUEBOOK
      Hecks.bluebook "Target" do
        vision "the domain that attaches a second, vendored bluebook"
        core

        aggregate "Widget" do
          description "a widget"
          identified_by :ref

          value_object "Ref" do
            attribute :value, String
            invariant("a widget has a ref") { !value.to_s.empty? }
          end

          attribute :ref, Ref

          command "Make" do
            role "Someone"
            goal "make a widget"
            attribute :ref, Ref
            emits "WidgetMade"
          end

          query "All" do
          end
        end
      end
    BLUEBOOK
  end

  def notes_bluebook
    <<~BLUEBOOK
      Hecks.bluebook "Notes" do
        vision "a tiny vendored chapter attached by uses_embryonaut_bluebook"
        core

        aggregate "Note" do
          description "a note"
          identified_by :ref

          value_object "Ref" do
            attribute :value, String
            invariant("a note has a ref") { !value.to_s.empty? }
          end

          attribute :ref, Ref

          command "Write" do
            role "Someone"
            goal "write a note"
            attribute :ref, Ref
            emits "NoteWritten"
          end

          query "All" do
          end
        end
      end
    BLUEBOOK
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # A target domain whose own bluebook directory holds EXACTLY ONE
  # `.bluebook` file of its own — the single-file shape the fallback in
  # `EraCheck.source_text_for` special-cases — attaching a second,
  # vendored bluebook via `uses_embryonaut_bluebook`. Both hecksagons
  # also `uses_framework "Governance"`, purely to satisfy the ordinary
  # "a command with a role needs an authorization provider" boot gate —
  # unrelated to the bug itself.
  def write_domain(dir)
    write(File.join(dir, "bluebook", "target.bluebook"), target_bluebook)
    write(
      File.join(dir, "vendor", "embryonaut_bluebooks", "notes", "bluebook", "notes.bluebook"),
      notes_bluebook
    )
    write(File.join(dir, "bluebook", "target.hecksagon"), <<~HECKSAGON)
      Hecks.hecksagon "Target" do
        uses_framework "Governance"
        uses_embryonaut_bluebook "notes"

        persisted_by "PostgresEra"
      end

      Hecks.hecksagon "Notes" do
        uses_framework "Governance"

        persisted_by "PostgresEra"
      end
    HECKSAGON
    write(File.join(dir, "bluebook", "target.world"), <<~WORLD)
      Hecks.world "Target" do
        persisted_by("PostgresEra") do
          database "#{owner_url}"
        end
      end

      Hecks.world "Notes" do
        persisted_by("PostgresEra") do
          database "#{owner_url}"
        end
      end
    WORLD
    File.join(dir, "bluebook")
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{VENDORED_BLUEBOOK_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{VENDORED_BLUEBOOK_DB}")
    admin.close
    FencedOwner.own!(VENDORED_BLUEBOOK_DB)
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{VENDORED_BLUEBOOK_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: VENDORED_BLUEBOOK_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(VENDORED_BLUEBOOK_DB)
  end

  it "stamps the SECOND bluebook's own era-1 held_text with its own source, not the first bluebook's" do
    Dir.mktmpdir do |dir|
      domain_dir = write_domain(dir)

      Hecks.boot(domain_dir, install_facade: false)

      db = PG.connect(dbname: VENDORED_BLUEBOOK_DB)
      rows = db.exec_params(
        "SELECT domain, ordinal, held_text FROM hecks_eras WHERE ordinal = 1 ORDER BY domain", []
      ).to_a
      db.close

      target_row = rows.find { |row| row["domain"] == "Target" }
      notes_row  = rows.find { |row| row["domain"] == "Notes" }

      expect(target_row["held_text"]).to include('Hecks.bluebook "Target"')
      # THE BUG, PINNED: before the fix, this held the TARGET's own
      # text (byte-identical to target_row["held_text"]) instead of
      # Notes' own.
      expect(notes_row["held_text"]).to include('Hecks.bluebook "Notes"')
      expect(notes_row["held_text"]).not_to eq(target_row["held_text"])
    end
  end

  it "boots a second time without refusing — nothing about the vendored bluebook's own shape ever changed" do
    Dir.mktmpdir do |dir|
      domain_dir = write_domain(dir)

      Hecks.boot(domain_dir, install_facade: false)

      expect { Hecks.boot(domain_dir, install_facade: false) }.not_to raise_error
    end
  end
end
