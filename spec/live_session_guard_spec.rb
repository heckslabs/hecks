require "spec_helper"

# A spec that reaches a real `claude --bg` is refused by name, so no session it starts outlives
# the example with its run recorded only in the spec's Memory.
RSpec.describe LiveSessionGuard do
  let(:real) { %w[claude --agent architect --bg -- 0901] }

  it "refuses a background claude that is not a stand-in under the temporary directory" do
    expect(described_class.refusal(real, { "PATH" => "/usr/bin" })).to include("a spec started a real claude session")
  end

  it "lets through a claude that neither starts nor lists sessions" do
    expect(described_class.refusal(%w[claude --version], {})).to be_nil
  end

  it "lets through a stand-in claude under the temporary directory" do
    Dir.mktmpdir("stand-in") do |dir|
      File.write(File.join(dir, "claude"), "#!/bin/sh\n").then { File.chmod(0o755, File.join(dir, "claude")) }
      expect(described_class.refusal(real, { "PATH" => dir })).to be_nil
    end
  end

  it "looks past a niceness prefix" do
    expect(described_class.refusal(["nice", "-n", "10", *real], { "PATH" => "/usr/bin" })).not_to be_nil
  end
end
