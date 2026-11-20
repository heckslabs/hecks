require "spec_helper"
require "tmpdir"
require "hecks/release/runner/gem_push"

# The gem step's push refuses before building anything when the vault's CLI is missing or the JS
# client is at another version.
RSpec.describe Hecks::Release::Runner::GemPush do
  around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

  def stub_vault(installed:)
    vault = instance_double(Hecks::Adapters::Codebase::SecretVault, installed?: installed)
    allow(Hecks::Adapters::Codebase::SecretVault).to receive(:new).and_return(vault)
  end

  def client_at(version)
    FileUtils.mkdir_p(File.join(@dir, "packages/hecks-client"))
    File.write(File.join(@dir, "packages/hecks-client/package.json"), %({"version":"#{version}"}))
  end

  def push = described_class.new(root: @dir, commands: Object.new).push!(Hecks::VERSION)

  it "refuses, pushing nothing, when the JS client is at another version" do
    client_at("0.0.1")
    stub_vault(installed: true)

    expect { push }.to raise_error(Hecks::Release::Runner::Refusal, /hecks-client is at 0\.0\.1 .*#{Hecks::VERSION}/o)
  end

  it "refuses when 1Password's CLI is not installed" do
    stub_vault(installed: false)

    expect { push }.to raise_error(Hecks::Release::Runner::Refusal, /1Password CLI \(op\) not found/)
  end
end
