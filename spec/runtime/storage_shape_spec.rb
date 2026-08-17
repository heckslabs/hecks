require "spec_helper"

# What bumps an era and what does not — a contract-critical boundary.
# The fixtures under spec/fixtures/eras/ each carry their own expected
# verdict in the filename (`bump_*` / `same_*`), so every suite that
# walks the directory reads one set of expectations and cannot silently
# disagree about whether an era exists.
RSpec.describe "the storage-shape projection" do
  FIXTURES = File.join(InMemoryDomain::ROOT, "spec", "fixtures", "eras")

  def self.project_fixture(path)
    registry = Hecksagain::Runtime::Registry.new
    loading = Hecksagain::Ports::Loading.bootstrap
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.eval(File.read(path), TOPLEVEL_BINDING, path, 1)
    end
    Hecksagain::Runtime::StorageShape.project(registry.bluebooks.values.first)
  end

  BASE = project_fixture(File.join(FIXTURES, "base.bluebook"))

  VARIANTS = Dir.glob(File.join(FIXTURES, "*.bluebook"))
                .reject { |path| File.basename(path) == "base.bluebook" }
                .sort.freeze

  it "has fixtures for both verdicts" do
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

  it "mints a stable name from the canonical serialization — Ruby-only, at mint time" do
    path = File.join(FIXTURES, "base.bluebook")
    registry = Hecksagain::Runtime::Registry.new
    loading = Hecksagain::Ports::Loading.bootstrap
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.eval(File.read(path), TOPLEVEL_BINDING, path, 1)
    end
    bluebook = registry.bluebooks.values.first

    label = Hecksagain::Runtime::StorageShape.mint_label(bluebook)
    expect(label).to match(/\A\h{6}\z/)
    expect(Hecksagain::Runtime::StorageShape.mint_hash(bluebook))
      .to start_with(label)
    expect(Hecksagain::Runtime::StorageShape.mint_label(bluebook)).to eq(label)
  end
end
