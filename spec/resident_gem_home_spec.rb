require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"

# A resident serves a caller whose gem environment resolves to the same gem set as its own,
# whatever spelling of GEM_HOME or BUNDLE_GEMFILE the caller carries, and refuses one that
# resolves to another, naming the variable.
RSpec.describe "a resident and a caller's gem environment" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:default_dir) { Gem.default_dir }

  around do |example|
    Dir.mktmpdir("hrgh") { |dir| @dir = dir && File.realpath(dir) and example.run }
  end

  def server_for(root) = resident::Server.new(root, File.join(root, "exe/hecks"))

  def refusal(env, root = @dir)
    server = server_for(root)
    server.instance_variable_set(:@environment, {})
    server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
    server.send(:unservable, { script: File.join(root, "exe/hecks"), env: env })
  end

  before do
    FileUtils.mkdir_p(File.join(@dir, "exe"))
    FileUtils.touch([File.join(@dir, "exe/hecks"), File.join(@dir, "Gemfile")])
  end

  it "serves a caller whose GEM_HOME is the directory gems resolve to without it" do
    expect(refusal({ "GEM_HOME" => default_dir })).to be_nil
  end

  it "serves a GEM_HOME that reaches the default directory through a symlink" do
    link = File.join(@dir, "gems-link")
    File.symlink(File.realpath(default_dir), link)
    expect(refusal({ "GEM_HOME" => link })).to be_nil
  end

  it "serves a BUNDLE_GEMFILE that reaches the checkout's Gemfile through a symlink" do
    link = File.join(@dir, "Gemfile.link")
    File.symlink(File.join(@dir, "Gemfile"), link)
    expect(refusal({ "BUNDLE_GEMFILE" => link, "GEM_HOME" => default_dir })).to be_nil
  end

  def other_homes
    other = File.join(@dir, "other")
    FileUtils.mkdir_p(other)
    File.symlink(other, File.join(@dir, "other-link"))
    [other, File.join(@dir, "other-link"), File.join(@dir, "missing")]
  end

  it "refuses a GEM_HOME that names another directory, a symlink to one or a missing one",
     :aggregate_failures do
    other_homes.each { |home| expect(refusal({ "GEM_HOME" => home })).to eq("env:GEM_HOME") }
  end

  it "still refuses a GEM_PATH, since it adds to the gem set whatever GEM_HOME is" do
    expect(refusal({ "GEM_PATH" => default_dir })).to eq("env:GEM_PATH")
  end
end
