require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/embryonaut_bluebook"
require "hecks/hecks/adapters/git_rehearsal"

# A temporary tree holding a copy of the vendored delivery package and the specs beside it.
class LockedPackageTree
  PACKAGE = "lib/hecks/vendor/acme_bluebooks/delivery".freeze
  SOURCE = File.join(Hecks::Tools::ROOT, "lib/hecks/vendor/embryonaut_bluebooks/delivery")

  attr_reader :root

  def initialize
    @root = Dir.mktmpdir("hecks-spec-map-locked")
    FileUtils.mkdir_p(File.join(root, PACKAGE))
    %w[bluebook lib].each { |name| copy(name) }
    copy("bluebook.lock")
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

  def copy(name) = FileUtils.cp_r(File.join(SOURCE, name), File.join(root, PACKAGE, name))
end

# A change under a locked vendored package runs the spec that names the package's directory, and
# the lock stops matching the files once the change is made.
RSpec.describe Hecks::Adapters::GitRehearsal::SpecMap, "#map over a locked package" do
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
