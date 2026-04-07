require "spec_helper"
require "hecks/chapters/runtime"

RSpec.describe Hecks::Chapters::Runtime::Mixins do
  subject(:domain) { Hecks::Chapters::Runtime.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes model and dispatch mixins" do
    expect(names).to include("ModelMixinInternal", "DispatchMixin")
  end

  it "includes validation and lifecycle aggregates" do
    expect(names).to include("ReferenceValidation", "LifecycleSteps")
  end

  it "includes composite specification aggregates" do
    expect(names).to include("AndSpecification", "OrSpecification",
                             "NotSpecification")
  end

  it "includes domain versioning aggregates" do
    expect(names).to include("BreakingBumper", "BreakingClassifier")
  end

  it "LifecycleSteps has Transition command" do
    agg = domain.aggregates.find { |a| a.name == "LifecycleSteps" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Transition")
  end

  it "contributes at least 9 mixin aggregates" do
    mixin_names = %w[ModelMixinInternal DispatchMixin ReferenceValidation
                     LifecycleSteps AndSpecification OrSpecification
                     NotSpecification BreakingBumper BreakingClassifier]
    present = mixin_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 9
  end
end
