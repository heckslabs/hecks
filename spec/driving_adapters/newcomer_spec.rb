require "spec_helper"
require "tmpdir"
require "fileutils"

# A folder with no bluebook in it gets the help for someone starting out: how to begin, and
# nothing that acts on a domain that is not there yet.
RSpec.describe Hecks::Adapters::Driving::Newcomer do
  let(:root) { Dir.mktmpdir("newcomer") }

  after { FileUtils.rm_rf(root) }

  describe ".applies?" do
    it "is true in a folder with no bluebook" do
      expect(described_class.applies?(root, {})).to be(true)
    end

    it "is false once a bluebook stands in the folder or a folder below it", :aggregate_failures do
      FileUtils.mkdir_p(File.join(root, "bluebook"))
      File.write(File.join(root, "bluebook", "shop.bluebook"), "")

      expect(described_class.applies?(root, {})).to be(false)
      expect(described_class.applies?(File.join(root, "bluebook"), {})).to be(false)
    end

    it "is false in a hecks checkout" do
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "hecks.gemspec"), "")

      expect(described_class.applies?(root, {})).to be(false)
    end
  end

  describe ".audience" do
    it "lists only the newcomer commands, and points at no chapters" do
      expect(described_class.audience(newcomer: %w[launch.init], chapters: %w[Deploy]))
        .to eq(only: %w[launch.init], chapters: [])
    end

    it "gives none when the setting names no newcomer commands, or there is no setting", :aggregate_failures do
      expect(described_class.audience(chapters: %w[Deploy])).to be_nil
      expect(described_class.audience(nil)).to be_nil
    end
  end
end
