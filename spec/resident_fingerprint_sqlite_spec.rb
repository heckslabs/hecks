require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/fingerprint"

# A lib tree with a database and its sidecars beside a declaration, and a clock the spec moves.
RSpec.shared_context "with a database tree" do
  let(:now) { [0.0] }
  let(:fingerprint) do
    Hecks::Adapters::Driving::Resident::Fingerprint.new(@root, clock: -> { now.first })
  end

  around do |example|
    Dir.mktmpdir("hecks-fingerprint-sqlite") do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "lib/hecks/data"))
      write("a.rb", "1\n")
      %w[agreement.db agreement.db-wal agreement.db-shm agreement.db-journal].each { |f| write("data/#{f}", "1\n") }
      example.run
    end
  end

  def write(name, text) = File.write(File.join(@root, "lib/hecks", name), text)

  def later(seconds = 31.0) = now[0] += seconds
end

# A database and its write-ahead sidecars are rewritten while a resident stands; they are not
# declarations, so rewriting one never retires the resident.
RSpec.describe Hecks::Adapters::Driving::Resident::Fingerprint, "with SQLite files under lib" do
  include_context "with a database tree"

  it "ignores a rewritten database and each of its sidecars" do
    fingerprint.mark!
    %w[agreement.db agreement.db-wal agreement.db-shm agreement.db-journal].each { |f| write("data/#{f}", "longer text\n") }
    later
    expect(fingerprint.changed?).to be(false)
  end

  it "ignores a sidecar created and removed" do
    fingerprint.mark!
    File.delete(File.join(@root, "lib/hecks/data/agreement.db-wal"))
    later
    expect(fingerprint.changed?).to be(false)
  end

  it "still sees an edit to a declaration" do
    fingerprint.mark!
    write("a.rb", "changed again\n")
    later
    expect(fingerprint.changed?).to be(true)
  end
end
