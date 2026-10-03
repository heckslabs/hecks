require "spec_helper"
require "open3"
require "rbconfig"
require "hecks/cli/project_cli"

# `memory_verbs` in the Hecks world's `launcher` setting makes the generated `exe/hecks` run
# those verbs on the Memory environment unless the caller chose one (ADR 0082), so a clone's
# first command needs no database.
RSpec.describe "the launcher's memory verbs" do
  it "is projected into exe/hecks from the world, so the committed launcher is current" do
    source = Hecks::CLI::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "hecks project_cli",
                                             executable: "exe/hecks", memory_verbs: %w[console], opted: true)

    expect(source).to include('MEMORY_VERBS = %w[console].freeze')
    expect(File.read(File.join(InMemoryDomain::ROOT, "exe/hecks"))).to include('MEMORY_VERBS = %w[console].freeze')
  end

  it "refuses a verb that is not a plain word" do
    expect { Hecks::CLI::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "x", executable: "exe/hecks", memory_verbs: ["a b"]) }
      .to raise_error(ArgumentError, /memory verb/)
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
