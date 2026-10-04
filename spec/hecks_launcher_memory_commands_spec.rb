require "spec_helper"
require "open3"
require "rbconfig"
require "hecks/cli/project_cli"

# `memory_commands` in the Hecks world's `launcher` setting makes the generated `exe/hecks` run
# those commands on the Memory environment unless the caller chose one (ADR 0084), so a clone's
# first command needs no database.
RSpec.describe "the launcher's memory commands" do
  it "is projected into exe/hecks from the world, so the committed launcher is current" do
    source = Hecks::CLI::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "hecks project_cli",
                                             executable: "exe/hecks", memory_commands: %w[console init interview], opted: true)

    expect(source).to include("MEMORY_COMMANDS = %w[console init interview].freeze")
    expect(File.read(File.join(InMemoryDomain::ROOT,
                               "exe/hecks"))).to include("MEMORY_COMMANDS = %w[console init interview].freeze")
  end

  it "makes a memory command wait for its result, and say why it was refused instead of printing the record" do
    source = Hecks::CLI::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "hecks project_cli",
                                             executable: "exe/hecks", memory_commands: %w[init], opted: true)

    expect(source).to include('ARGV << "--wait" if MEMORY_COMMANDS.include?(ARGV.first.to_s.chomp("!"))')
    expect(source).to include('JSON.parse(text).dig("state", "refusal", "value")')
  end

  it "refuses a command that is not a plain word" do
    expect { Hecks::CLI::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "x", executable: "exe/hecks", memory_commands: ["a b"]) }
      .to raise_error(ArgumentError, /memory command/)
  end

  it "opens the console with no database reachable and no environment variable" do
    env = { "PGHOST" => "/nonexistent-postgres-socket-dir", "PGPORT" => "1", "IRBRC" => File::NULL,
            "HECKS_ENVIRONMENT" => nil }
    _out, err, status = Open3.capture3(env, RbConfig.ruby, "exe/hecks", "console",
                                       stdin_data: "exit\n", chdir: InMemoryDomain::ROOT)

    expect(status).to be_success, err
    expect(err).not_to include("cannot bind PostgresEra")
  end
end
