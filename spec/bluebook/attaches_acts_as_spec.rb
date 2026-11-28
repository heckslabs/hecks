require "spec_helper"
require "hecks/runtime/role_shadow/report"

# `attaches "<name>", acts_as: "<Role>"` (ADR 0216): the role the attached bluebook's policies that
# declare no `acts_as` run their reactions as, for a package whose files its lock pins.
RSpec.describe "an attachment's acts_as" do
  def policy(acts_as = nil) = Hecks::Bluebook::Policy.new(name: "RecordIt", on_event: "Done", acts_as: acts_as)

  def attachment(acts_as) = Hecks::Bluebook::Attachment.new(name: "delivery", source: :vendor, acts_as: acts_as)

  it "gives a policy that declares no acts_as the attachment's role" do
    expect(policy.tap { |undeclared| undeclared.act_as_by_default("System") }.acts_as).to eq("System")
  end

  it "keeps the role a policy declares" do
    expect(policy("Operator").tap { |declared| declared.act_as_by_default("System") }.acts_as).to eq("Operator")
  end

  it "carries the role in the attachment's plain data" do
    expect(attachment("System").to_h).to eq(name: "delivery", source: "vendor", acts_as: "System")
  end

  it "leaves the key out of an attachment that names no role" do
    expect(attachment(nil).to_h).to eq(name: "delivery", source: "vendor")
  end

  it "runs the vendored delivery package's reactions as System in the hecks domain" do
    report = Hecks::Runtime::RoleShadow::Report.of_directory(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"))
    expect(report).not_to match(/^reaction   Delivery::/)
  end
end
