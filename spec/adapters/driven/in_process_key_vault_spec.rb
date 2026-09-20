require "hecks"

RSpec.describe Hecks::Adapters::InProcessKeyVault do
  before { described_class.reset! }

  it "issues a key whose material is fetchable behind its own reference" do
    key_reference = described_class.issue(subject_id: "attendee-482")

    expect(described_class.fetch(key_reference)).to be_a(String)
  end

  it "issues a distinct reference and secret per call, even for the same subject" do
    first  = described_class.issue(subject_id: "attendee-482")
    second = described_class.issue(subject_id: "attendee-482")

    expect(first).not_to eq(second)
    expect(described_class.fetch(first)).not_to eq(described_class.fetch(second))
  end

  it "makes a destroyed key's material permanently unfetchable" do
    key_reference = described_class.issue(subject_id: "attendee-482")

    expect(described_class.destroy(key_reference: key_reference)).to be(true)
    expect(described_class.fetch(key_reference)).to be_nil
  end

  it "reports false for a reference already destroyed, or never issued" do
    key_reference = described_class.issue(subject_id: "attendee-482")
    described_class.destroy(key_reference: key_reference)

    expect(described_class.destroy(key_reference: key_reference)).to be(false)
    expect(described_class.destroy(key_reference: "never-issued")).to be(false)
  end

  it "starts over empty after reset!" do
    key_reference = described_class.issue(subject_id: "attendee-482")
    described_class.reset!

    expect(described_class.fetch(key_reference)).to be_nil
  end
end
