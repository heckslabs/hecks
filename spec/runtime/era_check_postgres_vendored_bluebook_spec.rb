require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# Pins a fix: PostgresEra's era-1 self-mint for a second, vendored bluebook
# in a registry wrote the first bluebook's own source text into
# `hecks_eras.held_text` instead of the second bluebook's own.
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

  # Target's directory holds exactly one `.bluebook` file — the single-file
  # shape `EraCheck.source_text_for`'s fallback special-cases. The
  # `uses_framework "Governance"` calls only satisfy the role-authorization
  # boot gate and are unrelated to the bug this pins.
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

      Hecks.hecksagon "Governance" do
        Governance::RoleAssignment.persisted_by("PostgresEra")
        Governance::RoleTransition.persisted_by("PostgresEra")
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

      Hecks.world "Governance" do
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

      Hecks.boot(domain_dir, install_doors: false)

      db = PG.connect(dbname: VENDORED_BLUEBOOK_DB)
      rows = db.exec_params(
        "SELECT domain, ordinal, held_text FROM hecks_eras WHERE ordinal = 1 ORDER BY domain", []
      ).to_a
      db.close

      target_row = rows.find { |row| row["domain"] == "Target" }
      notes_row  = rows.find { |row| row["domain"] == "Notes" }

      expect(target_row["held_text"]).to include('Hecks.bluebook "Target"')
      # Pinned: pre-fix this held the target's own text instead of Notes' own.
      expect(notes_row["held_text"]).to include('Hecks.bluebook "Notes"')
      expect(notes_row["held_text"]).not_to eq(target_row["held_text"])
    end
  end

  it "boots a second time without refusing — nothing about the vendored bluebook's own shape ever changed" do
    Dir.mktmpdir do |dir|
      domain_dir = write_domain(dir)

      Hecks.boot(domain_dir, install_doors: false)

      expect { Hecks.boot(domain_dir, install_doors: false) }.not_to raise_error
    end
  end
end
