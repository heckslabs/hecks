require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# What bumps an era and what does not — a contract-critical boundary.
# The fixtures under spec/fixtures/eras/ each carry their own expected
# verdict in the filename (`bump_*` / `same_*`), so every suite that
# walks the directory reads one set of expectations and cannot silently
# disagree about whether an era exists.
RSpec.describe "the storage-shape projection" do
  FIXTURES = File.join(InMemoryDomain::ROOT, "spec", "fixtures", "eras")

  def self.load_fixture(path)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(File.read(path), TOPLEVEL_BINDING, path, 1)
    end
    registry.bluebooks.values.first
  end

  def self.project_fixture(path) = Hecks::Runtime::StorageShape.project(load_fixture(path))

  BASE = project_fixture(File.join(FIXTURES, "base.bluebook"))

  VARIANTS = Dir.glob(File.join(FIXTURES, "*.bluebook"))
                .reject { |path| File.basename(path) == "base.bluebook" }
                .sort.freeze

  it "has fixtures for both verdicts", :aggregate_failures do
    names = VARIANTS.map { |path| File.basename(path) }
    expect(names.count { |name| name.start_with?("bump_") }).to be >= 5
    expect(names.count { |name| name.start_with?("same_") }).to be >= 2
    expect(names).to all(match(/\A(bump_|same_)/))
  end

  VARIANTS.each do |path|
    name = File.basename(path)

    if name.start_with?("bump_")
      it "#{name} bumps the era" do
        expect(self.class.project_fixture(path)).not_to eq(BASE)
      end
    else
      it "#{name} does not bump the era" do
        expect(self.class.project_fixture(path)).to eq(BASE)
      end
    end
  end

  it "mints a stable name from the canonical serialization — Ruby-only, at mint time", :aggregate_failures do
    bluebook = self.class.load_fixture(File.join(FIXTURES, "base.bluebook"))

    label = Hecks::Runtime::StorageShape.mint_label(bluebook)
    expect(label).to match(/\A\h{6}\z/)
    expect(Hecks::Runtime::StorageShape.mint_hash(bluebook)).to start_with(label)
    expect(Hecks::Runtime::StorageShape.mint_label(bluebook)).to eq(label)
  end

  # spec/fixtures/storage_shape_vectors.json is the golden file rust/host/src/storage_shape.rs
  # asserts too, so a drift in either implementation fails a test on its own side.
  describe "the shared golden vectors" do
    # Just the two readers StorageShape takes of a bluebook, over an IR Hash.
    ShapeStub = Struct.new(:name, :dump) do
      def to_h = dump
    end

    SHAPE_VECTORS = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec", "fixtures", "storage_shape_vectors.json")))

    it "carries the real translation edge label among its vectors" do
      expect(SHAPE_VECTORS.map { |vector| vector["label"] }).to include("77625c")
    end

    SHAPE_VECTORS.each do |vector|
      it "#{vector["name"]} mints the canonical form, hash and label", :aggregate_failures do
        ir = vector["ir"] || JSON.parse(File.read(File.join(InMemoryDomain::ROOT, vector.fetch("ir_file"))))
        bluebook = ShapeStub.new(ir["name"], ir)

        expect(Hecks::Runtime::StorageShape.canonical(bluebook)).to eq(vector["canonical"])
        expect(Hecks::Runtime::StorageShape.mint_hash(bluebook)).to eq(vector["hash"])
        expect(Hecks::Runtime::StorageShape.mint_label(bluebook)).to eq(vector["label"])
      end
    end
  end
end
