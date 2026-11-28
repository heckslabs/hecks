require "spec_helper"
require "tmpdir"

# `PostgresEra` was removed in 8.0 (ADR 0182): its revision layout is chosen with
# `persisted_by "Postgres"` and `revisions true`. A binding that still names it fails at boot with
# a message naming the replacement; no alias is kept. The refusal comes before any adapter loads,
# so no database is needed.
RSpec.describe "a binding to the removed PostgresEra adapter" do
  REPLACEMENT = /which Hecks 8\.0 removed\. Write persisted_by "Postgres" plus `revisions true` in the hecksagon/

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

  # The refusal word for word; `rust/host/core/src/ir.rs` pins the same text.
  def whole_refusal
    "Lending: its hecksagon binds PostgresEra, which Hecks 8.0 removed. Write persisted_by \"Postgres\" plus " \
      "`revisions true` in the hecksagon (ADR 0182) instead: PostgresEra is now Postgres's revision layout, " \
      "chosen in the hecksagon."
  end

  # Boots a one-aggregate domain whose hecksagon carries `wiring` and whose world carries `world`.
  def boot_with(wiring, world: nil)
    Dir.mktmpdir("retired") do |dir|
      File.write(File.join(dir, "lending.bluebook"), bluebook_text)
      File.write(File.join(dir, "lending.hecksagon"), "Hecks.hecksagon \"Lending\" do\n#{wiring}\nend\n")
      File.write(File.join(dir, "lending.world"), "Hecks.world \"Lending\" do\n#{world}\nend\n") if world
      return Hecks.boot(dir, install_driving: false)
    end
  end

  it "refuses a hecksagon bind, naming the replacement" do
    expect { boot_with('  Lending::Loan.persisted_by("PostgresEra")') }
      .to raise_error(Hecks::Runtime::WiringError, /\ALending: its hecksagon binds PostgresEra, #{REPLACEMENT}/o)
  end

  it "says the whole refusal in the words the Rust host says it" do
    expect { boot_with('  persisted_by "PostgresEra"') }.to raise_error(Hecks::Runtime::WiringError, whole_refusal)
  end

  it "refuses the snake_case spelling the same way" do
    expect { boot_with('  persisted_by "postgres_era"') }
      .to raise_error(Hecks::Runtime::WiringError, /its hecksagon binds postgres_era, #{REPLACEMENT}/o)
  end

  it "refuses a world's default_adapter" do
    expect { boot_with("", world: '  default_adapter "PostgresEra"') }
      .to raise_error(Hecks::Runtime::WiringError, /\ALending: its world names PostgresEra, #{REPLACEMENT}/o)
  end

  it "refuses a world's persisted_by block" do
    expect { boot_with('  persisted_by "Memory"', world: %(  persisted_by("PostgresEra") { database "x" })) }
      .to raise_error(Hecks::Runtime::WiringError, /\ALending: its world names PostgresEra, #{REPLACEMENT}/o)
  end

  it "refuses a lookup of the removed adapter's class by its name" do
    registry = boot_with('  persisted_by "Memory"').registry

    expect { registry.adapter_class("postgres_era") }
      .to raise_error(Hecks::Runtime::WiringError, /\AHecks: an adapter lookup names postgres_era, #{REPLACEMENT}/o)
  end

  it "keeps no adapter declaration under the old name" do
    expect(boot_with('  persisted_by "Memory"').registry.adapters.keys & %w[Postgres PostgresEra]).to eq(["Postgres"])
  end
end
