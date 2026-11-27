require "spec_helper"
require "tmpdir"

# `revisions`, the hecksagon word that keeps schema revisions (ADR 0182). It is for Postgres only.
RSpec.describe "revisions, the hecksagon word for schema revisions" do
  def bluebook_text
    <<~RUBY
      Hecks.bluebook "Lending" do
        vision "Lend something and take it back."
        supporting

        aggregate "Loan" do
          description "A thing lent out."
          attribute :name, LoanName
          identified_by :name

          value_object "LoanName" do
            attribute :value, String, matches: :present
            invariant("a loan is named") { !value.to_s.empty? }
          end

          command "OpenLoan" do
            goal "Lend something out"
            attribute :name, LoanName
            sets :name
            emits "LoanOpened"
          end
        end
      end
    RUBY
  end

  # Boots a one-aggregate domain on Memory whose hecksagon carries `wiring`.
  def boot_with(wiring)
    Dir.mktmpdir("revisions") do |dir|
      File.write(File.join(dir, "lending.bluebook"), bluebook_text)
      File.write(File.join(dir, "lending.hecksagon"),
                 "Hecks.hecksagon \"Lending\" do\n  Lending::Loan.persisted_by(\"Memory\")\n#{wiring}\nend\n")
      return Hecks.boot(dir, install_driving: false)
    end
  end

  it "is off by default, so a domain without the word keeps the table layout" do
    expect(boot_with("").registry.hecksagon("Lending").revisions?).to be false
  end

  it "refuses at boot on Memory, naming the adapters that can keep revisions" do
    expect { boot_with("  revisions true") }
      .to raise_error(Hecks::Runtime::WiringError,
                      /sets revisions, but its persistence adapter is Memory — revisions need one of Postgres\z/)
  end

  # The Lending bluebook with a first aggregate, `Note`, shaped like `Loan`.
  def two_aggregate_text
    loan = bluebook_text[/^  aggregate "Loan".*?^  end\n/m]
    bluebook_text.sub(loan, "#{loan.gsub("Loan", "Note").gsub("loan", "note")}\n#{loan}")
  end

  # Loads a domain whose hecksagon carries `wiring` and verifies it without opening any store, so a
  # Postgres bind needs no database.
  def verify_with(wiring)
    Dir.mktmpdir("revisions") do |dir|
      File.write(File.join(dir, "lending.bluebook"), two_aggregate_text)
      File.write(File.join(dir, "lending.hecksagon"), "Hecks.hecksagon \"Lending\" do\n#{wiring}\nend\n")
      registry = Hecks::Runtime::Registry.new(root: dir)
      Hecks.with_registry(registry) { Hecks::Ports::Loading.bootstrap.tap(&:load_library).load_domain(dir) }
      return registry.verify!(open_stores: false)
    end
  end

  it "does not refuse a domain that keeps one aggregate in Memory and another in Postgres" do
    wiring = "  Lending::Note.persisted_by(\"Memory\")\n  Lending::Loan.persisted_by(\"Postgres\")\n  revisions true"

    expect { verify_with(wiring) }.not_to raise_error
  end

  it "does not refuse when revisions is left out" do
    expect { boot_with("") }.not_to raise_error
  end
end
