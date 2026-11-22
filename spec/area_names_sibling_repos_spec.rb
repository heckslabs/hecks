require "spec_helper"
require "tmpdir"
require "fileutils"

# A work item's area may name a path in a sibling checkout the store serves, such as Switchyard:
# its first segment is the sibling directory beside this checkout.
RSpec.describe Hecks::Adapters::AreaNames do
  around do |example|
    Dir.mktmpdir do |dir|
      @parent = dir
      FileUtils.mkdir_p(File.join(dir, "hecks", "lib"))
      FileUtils.mkdir_p(File.join(dir, "switchyard", "bluebook"))
      FileUtils.mkdir_p(File.join(dir, "switchyard", ".git"))
      example.run
    end
  end

  def unnamed(*words) = described_class.unnamed(words, root: File.join(@parent, "hecks"))

  it "names a path that exists in the sibling checkout" do
    expect(unnamed("switchyard/bluebook", "lib")).to eq([])
  end

  it "leaves unnamed a sibling path that does not exist" do
    expect(unnamed("switchyard/handcar")).to eq(["switchyard/handcar"])
  end

  it "treats a first segment with no sibling checkout as a path in this one" do
    expect(unnamed("elsewhere/bluebook")).to eq(["elsewhere/bluebook"])
  end
end
