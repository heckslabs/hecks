require "spec_helper"

RSpec.describe GitIdentityFree, "#apply!" do
  it "names an existing empty configuration after the run's tmp is emptied", :aggregate_failures do
    path = described_class.apply!({})["GIT_CONFIG_GLOBAL"]
    RunSandbox.disarm!
    RunSandbox.arm!
    expect(File.exist?(path)).to be(true)
    expect(File.read(path)).to eq("")
  end
end
