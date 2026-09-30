require "spec_helper"
require "hecks/hecks/adapters/codebase/secret_vault"
require_relative "../../release/support/recording_commands"

RSpec.describe Hecks::Adapters::Codebase::SecretVault do
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: "a" * 40, version: "1.0.0") }
  let(:vault) { described_class.new(commands: commands) }

  it "runs a program under `op run` with the env file, showing its output" do
    vault.run!("release/x.env", "gem", "push", "a.gem", chdir: "/work")

    call = commands.runs.first
    expect(call.argv).to eq(["op", "run", "--env-file=release/x.env", "--", "gem", "push", "a.gem"])
    expect(call.chdir).to eq("/work")
  end

  it "says whether the 1Password CLI is installed" do
    expect(vault).to be_installed

    commands.answer("op", "--version", success: false, stderr: "No such file or directory - op")

    expect(vault).not_to be_installed
  end
end
