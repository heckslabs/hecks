require "spec_helper"
require "open3"
require "rbconfig"
require "hecks/tools/project_cli"

# The executable launcher starts Ruby without rubygems, so a line a resident serves skips the
# ~20 ms their load costs, and it loads them itself once the probe has missed. Every other launcher
# has no probe and starts as it always did.
RSpec.describe "the launcher's shebang" do
  let(:root) { InMemoryDomain::ROOT }
  let(:prelude) { Hecks::Tools::ProjectCli::LaunchPrelude }

  def first_line(source) = source.lines.first.chomp

  def source(**options)
    Hecks::Tools::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "hecks project_cli", **options)
  end

  # Runs a launcher line cold, in a new process, so rubygems and bundler must come from the launcher.
  def cold(*command)
    env = { "HECKS_NO_RESIDENT" => "1", "HECKS_USAGE" => "off" }
    Open3.capture3(env, *command, chdir: root)
  end

  def answers?(*command)
    out, _err, status = cold(*command)
    status.success? && out.include?("hecks <command>!")
  end

  it "starts the executable launcher without rubygems" do
    expect(first_line(source(executable: "exe/hecks", opted: true))).to eq(prelude::EXECUTABLE_SHEBANG)
  end

  it "keeps the plain shebang on a launcher beside a client's domain" do
    expect(first_line(source)).to eq(prelude::PLAIN_SHEBANG)
  end

  it "is the shebang the committed exe/hecks carries" do
    expect(first_line(File.read(File.join(root, "exe/hecks")))).to eq(prelude::EXECUTABLE_SHEBANG)
  end

  it "loads rubygems itself when the probe misses", :aggregate_failures do
    text = File.read(File.join(root, "exe/hecks"))

    expect(text).to include('require "rubygems" unless defined?(Gem)')
    expect(text.index("Resident::Client.run")).to be < text.index('require "rubygems"')
  end

  it "answers cold through its shebang" do
    expect(answers?(File.join(root, "exe/hecks"), "--help")).to be(true)
  end

  it "answers cold under bundle exec" do
    expect(answers?("bundle", "exec", File.join(root, "exe/hecks"), "--help")).to be(true)
  end

  it "answers cold when run as a script argument to ruby" do
    expect(answers?(RbConfig.ruby, File.join(root, "exe/hecks"), "--help")).to be(true)
  end
end
