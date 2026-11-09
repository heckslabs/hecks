require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/fingerprint"

# How often a resident looks at the files it was built from, and how much a look costs (ADR 0201):
# an answer is reused for a second, a look re-stats the files and directories already listed with
# no walk of the tree, and the tree is listed again every thirty seconds and whenever a look finds
# something different.
RSpec.describe Hecks::Adapters::Driving::Resident::Fingerprint do
  let(:time) { [0.0] }
  let(:fingerprint) { described_class.new(@root, clock: -> { time.first }) }
  let(:old) { Time.now - 3600 }

  around do |example|
    Dir.mktmpdir("hecks-fingerprint-looks") do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "lib/hecks"))
      File.write(File.join(root, "lib/hecks/a.rb"), "A = 1\n")
      example.run
    end
  end

  # Marks the fingerprint, with every directory's time put well in the past so that a file added
  # later moves it.
  def marked
    Dir.glob(File.join(@root, "**", "*/")).push(@root).each { |dir| File.utime(old, old, dir) }
    fingerprint.mark!
  end

  def edit(name = "lib/hecks/a.rb", text: "A = 22\n") = File.write(File.join(@root, name), text)

  def changed_at?(seconds)
    time[0] = seconds
    fingerprint.changed?
  end

  # How many times the tree has been walked since this was called.
  def walks
    count = [0]
    allow(Dir).to receive(:glob).and_wrap_original do |original, *args, **options|
      count[0] += 1
      original.call(*args, **options)
    end
    count
  end

  describe "reusing an answer" do
    it "keeps the answer for a second and sees an edit made in that second after it", :aggregate_failures do
      marked
      changed_at?(0.0)
      edit
      expect(changed_at?(0.5)).to be(false)
      expect(changed_at?(1.5)).to be(true)
    end

    it "does not look again within the second" do
      marked
      changed_at?(2.0)
      allow(File).to receive(:stat).and_call_original
      changed_at?(2.4)
      expect(File).not_to have_received(:stat)
    end
  end

  describe "a look between full listings" do
    before { marked }

    it "does not walk the tree when nothing changed" do
      count = walks
      changed_at?(5.0)
      expect(count.first).to eq(0)
    end

    it "sees a file edited in place, from its own stat, and walks the tree to confirm", :aggregate_failures do
      count = walks
      edit
      expect(changed_at?(5.0)).to be(true)
      expect(count.first).to be_positive
    end

    it "sees a file added to a listed directory, from the directory's time" do
      edit("lib/hecks/b.rb", text: "")
      expect(changed_at?(5.0)).to be(true)
    end

    it "sees a file that went" do
      File.delete(File.join(@root, "lib/hecks/a.rb"))
      expect(changed_at?(5.0)).to be(true)
    end
  end

  describe "a directory whose time moved with the listing the same" do
    def touched_and_removed
      scratch = File.join(@root, "lib/hecks/scratch")
      File.write(scratch, "")
      File.delete(scratch)
    end

    before do
      marked
      touched_and_removed
    end

    it "walks the tree, finds nothing, and says it did not change", :aggregate_failures do
      count = walks
      expect(changed_at?(5.0)).to be(false)
      expect(count.first).to be_positive
    end

    it "is quiet on the next look, which walks nothing" do
      changed_at?(5.0)
      count = walks
      changed_at?(7.0)
      expect(count.first).to eq(0)
    end
  end

  describe "the full listing" do
    before { marked }

    it "does not come before thirty seconds" do
      count = walks
      changed_at?(29.0)
      expect(count.first).to eq(0)
    end

    it "walks the tree again after thirty seconds even when no look found a difference" do
      count = walks
      changed_at?(31.0)
      expect(count.first).to be_positive
    end
  end

  describe "before it was marked" do
    it "says it changed, since it knows nothing to compare with" do
      expect(fingerprint.changed?).to be(true)
    end
  end

  describe "once it has changed" do
    it "keeps saying so, since the resident retires on the first" do
      marked
      edit
      changed_at?(5.0)
      File.write(File.join(@root, "lib/hecks/a.rb"), "A = 1\n")
      expect(changed_at?(9.0)).to be(true)
    end
  end
end
