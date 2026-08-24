require "hecks"

RSpec.describe Hecks::Adapters::SecureRandomIdentity do
  it "generates a real UUID" do
    expect(described_class.uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
  end

  it "never repeats across calls" do
    ids = Array.new(100) { described_class.uuid }
    expect(ids.uniq.size).to eq(100)
  end
end
