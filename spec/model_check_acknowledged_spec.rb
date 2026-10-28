require "spec_helper"
require "hecks/bluebook/model_check"
require "tmpdir"

# `acknowledges :key_by_value` and `:orphaned_reference` excuse the one attribute or referenced
# aggregate they name (ADR 0151), and nothing else on the aggregate.
RSpec.describe "acknowledged key_by_value and orphaned_reference findings" do
  PAIR_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Pair" do
      aggregate "Ledger" do
        attribute :code, LedgerCode
        identified_by :code
        value_object("LedgerCode") { attribute :value, String }
        lifecycle :status, default: "open" do
          transition "Close" => "closed", from: "open"
        end
        command("Close") { reference_to Ledger; emits "LedgerClosed" }
      end

      aggregate "Entry" do
        %<words>s
        reference_to Ledger
        attribute :code, EntryCode
        attribute :other_code, LedgerCode
        attribute :copied_code, LedgerCode
        identified_by :code
        value_object("EntryCode") { attribute :value, String }
        lifecycle :status, default: "open" do
          transition "Void" => "void", from: "open"
        end
        command("Void") { reference_to Entry; emits "EntryVoided" }
      end
    end
  BLUEBOOK

  def findings(words)
    Dir.mktmpdir("acknowledged") do |dir|
      path = File.join(dir, "pair.bluebook")
      File.write(path, format(PAIR_BLUEBOOK, words: words))
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { load_bluebook_files(path) }
      bluebook = registry.bluebooks.values.first
      Hecks::Bluebook::ModelCheck.reference_findings(bluebook).map { |found| [found.kind, found.subject] }
    end
  end

  def acknowledging(kind, subject) = %(acknowledges :#{kind}, "on purpose", of: :#{subject})

  it "reports both findings when nothing is acknowledged", :aggregate_failures do
    reported = findings("")
    expect(reported).to include([:orphaned_reference, "Entry -> Ledger"])
    expect(reported).to include([:key_by_value, "Entry.other_code"], [:key_by_value, "Entry.copied_code"])
  end

  it "leaves an acknowledged orphaned reference out" do
    expect(findings(acknowledging(:orphaned_reference, "Ledger"))).not_to include([:orphaned_reference, "Entry -> Ledger"])
  end

  it "leaves out the attribute an acknowledged key_by_value names" do
    expect(findings(acknowledging(:key_by_value, "other_code"))).not_to include([:key_by_value, "Entry.other_code"])
  end

  it "still reports another attribute of the same aggregate" do
    expect(findings(acknowledging(:key_by_value, "other_code"))).to include([:key_by_value, "Entry.copied_code"])
  end

  it "does not let an acknowledgement of one kind excuse the other" do
    expect(findings(acknowledging(:key_by_value, "Ledger"))).to include([:orphaned_reference, "Entry -> Ledger"])
  end
end
