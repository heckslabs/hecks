require "spec_helper"
require "hecks/bluebook/model_check"

BLANK_RESULT_IDENTITY = proc do
  value_object("Key") { attribute :value, String, matches: :present }
  attribute :key, Key
  attribute :report, Report, optional: true
  identified_by :key
end

BLANK_RESULT_RECORD = proc do
  command("Record") do
    attribute :report, Report
    sets :report
  end
end

# Builds a scratch bluebook whose one command records a result typed by the given declaration.
module BlankResultProbe
  # @param report [Proc] the value object declaration for Report
  # @return [Array<Hecks::Bluebook::ModelCheck::Finding>] the blank result findings
  def blank_findings(report)
    bluebook = Hecks.bluebook("Probe") do
      aggregate("Run") { [BLANK_RESULT_IDENTITY, report, BLANK_RESULT_RECORD].each { |part| instance_exec(&part) } }
    end
    Hecks::Bluebook::ModelCheck.call(bluebook).select { |finding| finding.kind == :blank_result_type }
  end
end

# A command result typed as a bare String accepts a blank; the model check names the type.
RSpec.describe "the blank result model check" do
  include BlankResultProbe

  around { |example| Hecks.with_registry(Hecks::Runtime::Registry.new) { example.run } }

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
