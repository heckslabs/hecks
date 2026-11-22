require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"

# A resident serves a caller whose BUNDLE_GEMFILE names a copy of the checkout's Gemfile and
# lock, since the copy resolves to the same gems, and refuses a copy that differs or has no lock.
RSpec.describe "a resident and a caller's copy of the Gemfile" do
  let(:resident) { Hecks::Adapters::Driving::Resident }

  around do |example|
    Dir.mktmpdir("hrgc") { |dir| @dir = dir && File.realpath(dir) and example.run }
  end

  def refusal(env)
    server = resident::Server.new(@dir, File.join(@dir, "exe/hecks"))
    server.instance_variable_set(:@environment, {})
    server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
    server.send(:unservable, { script: File.join(@dir, "exe/hecks"), env: env })
  end

  def write(dir, gemfile: "gem 'a'\n", lock: "a (1)\n")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "Gemfile"), gemfile)
    File.write(File.join(dir, "Gemfile.lock"), lock) if lock
    File.join(dir, "Gemfile")
  end

  before do
    FileUtils.mkdir_p(File.join(@dir, "exe"))
    FileUtils.touch(File.join(@dir, "exe/hecks"))
    write(@dir)
  end

  it "serves a BUNDLE_GEMFILE naming a copy with the same Gemfile and lock" do
    expect(refusal({ "BUNDLE_GEMFILE" => write(File.join(@dir, "copy")) })).to be_nil
  end

  it "refuses a copy whose lock names other gems" do
    copy = write(File.join(@dir, "copy"), lock: "a (2)\n")
    expect(refusal({ "BUNDLE_GEMFILE" => copy })).to eq("env:BUNDLE_GEMFILE")
  end

  it "refuses a copy whose Gemfile differs" do
    copy = write(File.join(@dir, "copy"), gemfile: "gem 'b'\n")
    expect(refusal({ "BUNDLE_GEMFILE" => copy })).to eq("env:BUNDLE_GEMFILE")
  end

  it "refuses a copy with no lock" do
    expect(refusal({ "BUNDLE_GEMFILE" => write(File.join(@dir, "copy"), lock: nil) })).to eq("env:BUNDLE_GEMFILE")
  end

  it "refuses a copy when the checkout has no lock either" do
    File.delete(File.join(@dir, "Gemfile.lock"))
    expect(refusal({ "BUNDLE_GEMFILE" => write(File.join(@dir, "copy"), lock: nil) })).to eq("env:BUNDLE_GEMFILE")
  end
end
