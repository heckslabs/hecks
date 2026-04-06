require "spec_helper"

RSpec.describe Hecks::BluebookToggles do
  after { described_class.reset! }

  it "all toggles are enabled by default" do
    expect(described_class.all_enabled?).to be true
  end

  it "can disable and re-enable individual toggles" do
    described_class.disable(:dsl)
    expect(described_class.enabled?(:dsl)).to be false
    expect(described_class.all_enabled?).to be false

    described_class.enable(:dsl)
    expect(described_class.enabled?(:dsl)).to be true
  end

  it "rejects unknown toggle names" do
    expect { described_class.enable(:nonexistent) }.to raise_error(ArgumentError)
    expect { described_class.enabled?(:nonexistent) }.to raise_error(ArgumentError)
  end

  it "reset! restores defaults" do
    described_class.disable(:runtime)
    described_class.reset!
    expect(described_class.enabled?(:runtime)).to be true
  end
end
