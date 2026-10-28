require "spec_helper"
require "tmpdir"

# `acknowledges :kind, "why"` on an aggregate allows a finding model_check would report about it
# (ADR 0150). The word needs a kind the check emits and a reason in text.
RSpec.describe "acknowledges" do
  LEDGER_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ack" do
      aggregate "Ledger" do
        identified_by :code
        attribute :code, LedgerCode
        value_object("LedgerCode") { attribute :value, String }
        %<word>s
      end
    end
  BLUEBOOK

  def ledger(word)
    Dir.mktmpdir("acknowledges") do |dir|
      path = File.join(dir, "ack.bluebook")
      File.write(path, format(LEDGER_BLUEBOOK, word: word))
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { load_bluebook_files(path) }
      registry.bluebooks.values.first.aggregates.first
    end
  end

  def acknowledged = ledger('acknowledges :large_aggregate, "one ledger holds every entry"')

  it "holds the kind and the reason", :aggregate_failures do
    held = acknowledged.acknowledgements.first
    expect(held.finding).to eq(:large_aggregate)
    expect(held.reason).to eq("one ledger holds every entry")
  end

  it "emits the acknowledgements in the IR" do
    expect(acknowledged.to_h[:acknowledgements])
      .to eq([{ finding: "large_aggregate", subject: "", reason: "one ledger holds every entry" }])
  end

  it "emits an empty list when nothing is acknowledged" do
    expect(ledger("").to_h[:acknowledgements]).to eq([])
  end

  it "refuses a kind the check does not report" do
    expect { ledger('acknowledges :no_such_finding, "why"') }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /no_such_finding, a finding model_check does not report/)
  end

  it "refuses a blank reason" do
    expect { ledger('acknowledges :large_aggregate, "  "') }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /without a reason/)
  end

  def subject_of(word) = ledger(word).acknowledgements.first.subject

  it "holds the attribute a key_by_value acknowledgement is for" do
    expect(subject_of('acknowledges :key_by_value, "a path, not a record", of: :code')).to eq("code")
  end

  it "holds the aggregate an orphaned_reference acknowledgement is for" do
    expect(subject_of('acknowledges :orphaned_reference, "completes it", of: :Sweep')).to eq("Sweep")
  end

  it "emits the subject in the IR" do
    held = ledger('acknowledges :key_by_value, "a path", of: :code').to_h[:acknowledgements]
    expect(held).to eq([{ finding: "key_by_value", subject: "code", reason: "a path" }])
  end

  it "refuses a per-subject kind that names no subject" do
    expect { ledger('acknowledges :key_by_value, "a path"') }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /without saying which — add `of:`/)
  end

  it "refuses a subject on a kind that has none" do
    expect { ledger('acknowledges :large_aggregate, "why", of: :code') }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /with `of:`/)
  end
end
