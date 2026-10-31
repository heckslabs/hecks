require "spec_helper"
require "hecks/tools/project_cli"

# `exe/hecks` is written by `hecks project_cli` from the Hecks bluebook and its world's `launcher`
# setting. The committed file is the bootstrap: this spec fails when it drifts from the generator,
# and checks that every command of the command table answers `--help`.
RSpec.describe "exe/hecks" do
  let(:root) { File.expand_path("..", __dir__) }

  before(:all) do
    @hecks = Hecks.boot(File.join(File.expand_path("..", __dir__), "lib/hecks/hecks"), install_driving: false)
    names  = { "mcp" => "serve_mcp", "console" => "open_console" }
    options = { program: "hecks", names: names }
    @cli    = Hecks::Projector.call(:cli, bluebook: @hecks.registry.bluebook("Hecks"), options: options)
  end

  it "matches what project_cli generates for the Hecks bluebook" do
    expect { Hecks::Tools::ProjectCli.call(["lib/hecks/hecks", "--check"], program: "hecks", root: root) }
      .to output(%r{exe/hecks  ->  Hecks}).to_stdout
  end

  it "is executable" do
    expect(File.executable?(File.join(root, "exe/hecks"))).to be(true)
  end

  it "refuses a retired positional name with the launcher's own refusal", :aggregate_failures do
    %w[run docs narrate ir stores model_check smoke_test project_diagrams project_cli].each do |name|
      _out, status = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: [name], program: "hecks")
      expect(status).to eq(2)
    end
  end

  # The names whose `--help` the launcher does not answer.
  def unanswered(names)
    names.reject do |name|
      _out, status = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: [name, "--help"], program: "hecks")
      status.zero?
    end
  end

  it "answers --help for every command and question of the command table", :aggregate_failures do
    names = @cli[:names][:command].keys + @cli[:names][:question].keys

    expect(names).not_to be_empty
    expect(unanswered(names)).to eq([])
  end
end
