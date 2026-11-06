require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/scratch_postgres"
require_relative "../support/fenced_owner"
require_relative "../support/first_era_hold"

# Pins a fix: a vendored package whose bluebook is not the Pascal-cased package name (package
# `note` declaring `Notes`) had no source found for its era-1 mint, so the single-file fallback
# stamped the host domain's own text under the bluebook's name and the next boot refused.
RSpec.describe "PostgresRevision era-1 minting for a vendored bluebook named unlike its package", :io do
  include FirstEraHold

  BLUEBOOK_NAME_DB = "hecks_era_vendored_bluebook_name_spec".freeze

  BLUEBOOK_NAME_TARGET = <<~BLUEBOOK.freeze
    Hecks.bluebook "Target" do
      vision "the domain that attaches a vendored bluebook named unlike its package"
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

  BLUEBOOK_NAME_NOTES = BLUEBOOK_NAME_TARGET
                        .sub('"Target"', '"Notes"').sub("Widget", "Note").sub("widget", "note")
                        .sub("WidgetMade", "NoteWritten").sub('"Make"', '"Write"')
                        .sub("the domain that attaches a vendored bluebook named unlike its package",
                             "a vendored bluebook whose name is not its package's Pascal-cased name")

  BLUEBOOK_NAME_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Target" do
      attaches "Governance"
      attaches "note", from: :vendor

      persisted_by "Postgres"
      revisions true
    end

    Hecks.hecksagon "Notes" do
      attaches "Governance"

      persisted_by "Postgres"
      revisions true
    end

    Hecks.hecksagon "Note" do
    end

    Hecks.hecksagon "Governance" do
      Governance::RoleAssignment.persisted_by("Postgres")
      Governance::RoleTransition.persisted_by("Postgres")
    end
  HECKSAGON

  def owner_url = FencedOwner.url(BLUEBOOK_NAME_DB)

  def world_text
    %w[Target Notes Governance].map do |declaration|
      "Hecks.world \"#{declaration}\" do\n  persisted_by(\"Postgres\") do\n    database \"#{owner_url}\"\n  end\nend\n"
    end.join("\n")
  end

  # Holds era 1 for each bluebook the way the mint entry point does, then boots the directory.
  def boot_held(directory)
    hold_domain_eras!(directory: directory, url: owner_url)
    Hecks.boot(directory, install_driving: false)
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_domain(dir)
    write(File.join(dir, "bluebook", "target.bluebook"), BLUEBOOK_NAME_TARGET)
    write(File.join(dir, "vendor", "embryonaut_bluebooks", "note", "bluebook", "note.bluebook"), BLUEBOOK_NAME_NOTES)
    write(File.join(dir, "bluebook", "target.hecksagon"), BLUEBOOK_NAME_HECKSAGON)
    write(File.join(dir, "bluebook", "target.world"), world_text)
    File.join(dir, "bluebook")
  end

  def held_text_for(domain)
    db = PG.connect(dbname: BLUEBOOK_NAME_DB)
    db.exec_params("SELECT held_text FROM hecks_eras WHERE domain = $1 AND ordinal = 1", [domain]).first&.fetch("held_text")
  ensure
    db&.close
  end

  scratch_postgres BLUEBOOK_NAME_DB, fenced: true

  it "holds the bluebook's own source, not the domain's" do
    Dir.mktmpdir do |dir|
      boot_held(write_domain(dir))

      expect(held_text_for("Notes")).to include('Hecks.bluebook "Notes"')
    end
  end

  it "boots a second time without refusing" do
    Dir.mktmpdir do |dir|
      domain_dir = write_domain(dir)
      boot_held(domain_dir)

      expect { Hecks.boot(domain_dir, install_driving: false) }.not_to raise_error
    end
  end
end
