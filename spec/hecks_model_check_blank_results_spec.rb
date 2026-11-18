require "spec_helper"
require "hecks/bluebook/model_check"

# A command result typed as a bare String accepts a blank; the model check names the type.
RSpec.describe "the blank result model check" do
  around { |example| Hecks.with_registry(Hecks::Runtime::Registry.new) { example.run } }

  def blank_findings(report)
    bluebook = Hecks.bluebook("Probe") do
      aggregate "Run" do
        value_object("Key") { attribute :value, String, matches: :present }
        instance_exec(&report)
        attribute :key, Key
        identified_by :key
        command("Record") { attribute :report, Report }
      end
    end
    Hecks::Bluebook::ModelCheck.call(bluebook).select { |finding| finding.kind == :blank_result_type }
  end

  it "names a result type that holds no presence rule", :aggregate_failures do
    finding = blank_findings(proc { value_object "Report", String }).first
    expect(finding.subject).to eq("Run.Report")
    expect(finding.severity).to eq(:warning)
  end

  it "passes a result type with a presence rule" do
    report = proc { value_object("Report") { attribute :value, String, matches: :present } }
    expect(blank_findings(report)).to be_empty
  end
end
