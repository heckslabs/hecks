require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/fingerprint"

# A lib tree holding one of each kind of declaration, in a directory of its own.
RSpec.shared_context "with a settings tree" do
  let(:fingerprint) { Hecks::Adapters::Driving::Resident::Fingerprint.new(@root) }

  around do |example|
    Dir.mktmpdir("hecks-fingerprint-settings") do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "lib/hecks"))
      %w[a.rb x.local.world y.world z.local.hecksagon].each { |f| write(f, "1\n") }
      example.run
    end
  end

  def write(name, text) = File.write(File.join(@root, "lib/hecks", name), text)

  def value_after_editing(name)
    before = fingerprint.current
    write(name, "changed again\n")
    [before, fingerprint.current]
  end
end

# The owner's gitignored settings (`*.local.world`) are not part of what a resident was built from,
# so editing them does not retire a resident mid-roll; other declarations still do.
RSpec.describe Hecks::Adapters::Driving::Resident::Fingerprint, "#current" do
  include_context "with a settings tree"

  it "ignores an edit to a local world" do
    before, after = value_after_editing("x.local.world")
    expect(after).to eq(before)
  end

  it "sees an edit to a world" do
    before, after = value_after_editing("y.world")
    expect(after).not_to eq(before)
  end

  it "sees an edit to a local hecksagon" do
    before, after = value_after_editing("z.local.hecksagon")
    expect(after).not_to eq(before)
  end

  it "does not report a replaced local world as a change", :aggregate_failures do
    fingerprint.mark!
    write("new.tmp", "2\n")
    File.rename(File.join(@root, "lib/hecks/new.tmp"), File.join(@root, "lib/hecks/x.local.world"))
    expect(fingerprint.changed?).to be(false)
  end
end
