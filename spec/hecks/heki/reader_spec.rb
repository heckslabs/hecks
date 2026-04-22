# spec/hecks/heki/reader_spec.rb
#
# Contract for Hecks::Heki::Reader. Reads an existing .heki produced
# by the Rust runtime, and validates the three InvalidFormatError
# surfaces (bad magic, truncated header, corrupted zlib).
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks/heki/reader"
require "tempfile"

RSpec.describe Hecks::Heki::Reader do
  describe ".read" do
    it "reads an existing .heki file and returns a hash of records with ids" do
      path = File.expand_path("../../../hecks_conception/information/identity.heki", __dir__)
      data = described_class.read(path)
      expect(data).to be_a(Hash)
      expect(data.size).to be >= 1
      data.each_value do |record|
        expect(record).to be_a(Hash)
        expect(record).to have_key("id")
      end
    end

    it "raises InvalidFormatError on wrong magic" do
      Tempfile.create(["bad_magic", ".heki"]) do |f|
        f.binmode
        f.write("ZZZZ\x00\x00\x00\x00".b)
        f.flush
        expect { described_class.read(f.path) }.to raise_error(
          Hecks::Heki::InvalidFormatError, /bad magic/
        )
      end
    end

    it "raises InvalidFormatError on truncated file (magic only, no count/payload)" do
      Tempfile.create(["truncated", ".heki"]) do |f|
        f.binmode
        f.write("HEKI".b)
        f.flush
        expect { described_class.read(f.path) }.to raise_error(
          Hecks::Heki::InvalidFormatError
        )
      end
    end

    it "raises InvalidFormatError on corrupted zlib payload" do
      Tempfile.create(["bad_zlib", ".heki"]) do |f|
        f.binmode
        f.write("HEKI\x00\x00\x00\x01".b + "not zlib".b)
        f.flush
        expect { described_class.read(f.path) }.to raise_error(
          Hecks::Heki::InvalidFormatError, /zlib/
        )
      end
    end
  end
end
