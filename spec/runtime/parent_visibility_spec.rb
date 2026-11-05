require "spec_helper"

# The outcomes (a payload name shadows parent state, `parent.` stays explicit) are in
# examples/parent_visibility/bluebook/parent_visibility.behaviors. What stays here is what `expect`
# cannot say: the execution plan's read sets.
RSpec.describe "lexical parent state and explicit disambiguation" do
  let(:runtime) do
    path = File.join(InMemoryDomain::ROOT, "examples/parent_visibility/bluebook/parent_visibility.bluebook")
    Hecks.boot_files([path], install_driving: false)
  end

  before { runtime.dispatch("Visibility::Meter.Install", with: { code: "m-1", reading: { value: 10 } }) }

  it "reads the payload's reading in the execution plan when it shadows parent state" do
    plan = runtime.dispatch("Visibility::Meter.RaiseReading", to: "m-1", with: { reading: { value: 12 } }).execution_plan

    expect([plan.payload_read_set, plan.read_set]).to all(include(:reading))
  end
end
