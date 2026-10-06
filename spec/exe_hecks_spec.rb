require "spec_helper"
require "hecks/cli"
require "hecks/cli/project_cli"

# `exe/hecks` is written by `hecks project_cli` from the Hecks chapter and its world's `launcher`
# setting. The committed file is the bootstrap: this spec fails when it drifts from the generator,
# and checks that every command of the command table answers `--help`.
RSpec.describe "exe/hecks" do
  let(:root) { File.expand_path("..", __dir__) }

  before(:all) do
    @hecks = Hecks.boot(File.join(File.expand_path("..", __dir__), "lib/hecks/hecks"), install_doors: false)
    names  = { "mcp" => "serve_mcp", "console" => "open_console" }
    options = { program: "hecks", names: names }
    @cli    = Hecks::Projector.call(:cli, bluebook: @hecks.registry.bluebook("Hecks"), options: options)
  end

  it "matches what project_cli generates for the Hecks chapter" do
    expect { Hecks::CLI::ProjectCli.call(["lib/hecks/hecks", "--check"], program: "hecks", root: root) }
      .to output(%r{exe/hecks  ->  Hecks}).to_stdout
  end

  it "is executable" do
    expect(File.executable?(File.join(root, "exe/hecks"))).to be(true)
  end

  it "hands every name the gem shipped to Hecks::CLI" do
    legacy = File.read(File.join(root, "exe/hecks"))[/LEGACY = %w\[(.*?)\]/, 1].split

    expect(legacy).to eq(Hecks::CLI::COMMANDS.keys)
  end

  # The names, outside the shipped ones, whose `--help` the launcher does not answer.
  def unanswered(names)
    (names - Hecks::CLI::COMMANDS.keys).reject do |name|
      _out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, argv: [name, "--help"], program: "hecks")
      status.zero?
    end
  end

  it "answers --help for every command and question of the command table", :aggregate_failures do
    names = @cli[:names][:command].keys + @cli[:names][:question].keys

    expect(names).not_to be_empty
    expect(unanswered(names)).to eq([])
  end

  it "answers --help for the shipped names through Hecks::CLI", :aggregate_failures do
    Hecks::CLI::COMMANDS.each_key do |name|
      out = StringIO.new
      expect(Hecks::CLI.start([name, "--help"], out: out)).to eq(0)
      expect(out.string).to start_with("usage: hecks #{name}")
    end
  end
end
