require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/embryonaut_bluebook"
require "hecks/hecks/adapters/codebase/spec_map"

# A temporary tree holding a small vendored package, locked to its own digest, and the specs beside it.
class LockedPackageTree
  PACKAGE = "lib/hecks/vendor/acme_bluebooks/delivery".freeze

  attr_reader :root

  def initialize
    @root = Dir.mktmpdir("hecks-spec-map-locked")
    add("#{PACKAGE}/bluebook/delivery.bluebook", "Hecks.bluebook \"Delivery\" do\nend\n")
    add("#{PACKAGE}/bluebook/git.adapter", "Hecks.adapter \"Git\" do\nend\n")
    add("#{PACKAGE}/lib/adapters/git.rb", "# the adapter's Ruby\n")
    lock
    add("spec/delivery_lock_spec.rb", %(File.join(ROOT, "#{PACKAGE}")\n))
    add("spec/unrelated_spec.rb", "# nothing\n")
  end

  def add(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  def edit(path) = File.open(File.join(root, path), "a") { |file| file.write("\n") }

  def file = Dir.glob("#{PACKAGE}/bluebook/**/*.adapter", base: root).first

  def digest_matches?
    lock = Hecks::EmbryonautBluebook::Lock
    lock.digest_of(File.join(root, PACKAGE, "bluebook")) == lock.read(File.join(root, PACKAGE, "bluebook.lock")).digest
  end

  def remove = FileUtils.remove_entry(root)

  private

  def lock
    digest = Hecks::EmbryonautBluebook::Lock.digest_of(File.join(root, PACKAGE, "bluebook"))
    add("#{PACKAGE}/bluebook.lock", Hecks::EmbryonautBluebook::Lock.new(package: "delivery", version: "0.1.0",
                                                                        tag: "delivery-v0.1.0", commit: "0" * 40,
                                                                        digest: digest, shape: []).to_s)
  end
end

# A change under a locked vendored package runs the spec that names the package's directory, and
# the lock stops matching the files once the change is made.
RSpec.describe Hecks::Adapters::Codebase::SpecMap, "#map over a locked package" do
  let(:tree) { LockedPackageTree.new }
  let(:map) { described_class.new(tree.root) }

  after { tree.remove }

  it "selects the spec that names the package for a one-byte change beneath its lock" do
    expect(map.map([tree.file], limit: 60).specs).to eq(["spec/delivery_lock_spec.rb"])
  end

  it "selects nothing for a path beneath no lock" do
    tree.add("lib/hecks/other/thing.txt", "x")
    expect(map.map(["lib/hecks/other/thing.txt"], limit: 60).specs).to be_empty
  end

  it "says the lock is why the spec ran" do
    because = map.map([tree.file], limit: 60).because
    expect(because["spec/delivery_lock_spec.rb"]).to eq("#{LockedPackageTree::PACKAGE} is locked")
  end

  it "leaves the package's digest different from its lock after the edit", :aggregate_failures do
    expect(tree.digest_matches?).to be(true)
    tree.edit(tree.file)
    expect(tree.digest_matches?).to be(false)
  end
end
