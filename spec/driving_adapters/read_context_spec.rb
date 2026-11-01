require "spec_helper"

# A read of a checkout's state takes the session's checkout when it names none.
# A command never does: a write names its own target.
RSpec.describe Hecks::Adapters::Driving::CliRunner::ReadContext do
  let(:read) { { kind: :query, command: "Hecks::Workspace.Status" } }
  let(:write) { { kind: :command, command: "Hecks::Revision.Make" } }
  let(:session) { { "HECKS_CHECKOUT" => "/session/repo" } }

  it "takes the session checkout for a read that names none" do
    expect(described_class.fill(read, {}, env: session)).to eq(checkout: { value: "/session/repo" })
  end

  it "keeps the checkout a read names" do
    expect(described_class.fill(read, { checkout: { value: "/mine" } }, env: session))
      .to eq(checkout: { value: "/mine" })
  end

  it "never fills a write's checkout" do
    expect(described_class.fill(write, {}, env: session)).to eq({})
  end

  it "leaves a read alone when the session names no checkout" do
    expect(described_class.fill(read, {}, env: {})).to eq({})
  end
end
