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
      .to raise_error(Hecks::Runtime::WiringError, /sets revisions.*Memory.*Postgres, PostgresRevisions/)
  end

  it "does not refuse when revisions is left out" do
    expect { boot_with("") }.not_to raise_error
  end
end
