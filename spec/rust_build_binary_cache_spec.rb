require "spec_helper"
require "tmpdir"
require "hecks/rust_build/binary_cache"

# Native binaries kept by what built them: the same sources take the kept binary, a changed
# source builds again, and the cache holds the newest few.
RSpec.describe Hecks::RustBuild::BinaryCache do
  let(:cache) { Dir.mktmpdir("binary-cache") }
  let(:rust) { Dir.mktmpdir("rust-dir") }
  let(:source) { File.join(rust, "lib.rs") }

  before do
    File.write(source, "fn one() {}\n")
    allow(described_class).to receive_messages(directory: cache, compiler: "abc")
  end

  after { FileUtils.rm_rf([cache, rust]) }

  def key(feature = "pizzas") = described_class.key(rust, feature, [source])

  def built(contents = "binary")
    path = File.join(rust, "built")
    File.write(path, contents)
    path
  end

  it "keys on the bytes of the sources, not on their modification times", :aggregate_failures do
    first = key
    File.utime(Time.now + 60, Time.now + 60, source)

    expect(key).to eq(first)
    File.write(source, "fn two() {}\n")
    expect(key).not_to eq(first)
  end

  it "keys on the feature and the compiler", :aggregate_failures do
    expect(key("pizzas")).not_to eq(key("banking"))
    allow(described_class).to receive(:compiler).and_return("def")
    expect(key).to end_with("-def-pizzas")
  end

  it "gives back the binary it kept, executable, at the place asked" do
    described_class.save(key, built("kept"))
    place = File.join(rust, "debug", "rust-pizzas")

    expect([described_class.restore(key, place), File.read(place), File.executable?(place)]).to eq([true, "kept", true])
  end

  it "misses on a key it never kept" do
    expect(described_class.restore(key, File.join(rust, "nowhere"))).to be(false)
  end

  # Keeps three binaries, the first the oldest.
  def keep_three
    %w[a b c].each_with_index do |name, age|
      described_class.save("key-#{name}", built(name))
      File.utime(Time.now - (10 - age), Time.now - (10 - age), File.join(cache, "key-#{name}"))
    end
  end

  it "keeps the newest few and drops the rest" do
    stub_const("Hecks::RustBuild::BinaryCache::KEEP", 2)
    keep_three
    described_class.prune

    expect(Dir.children(cache).sort).to eq(%w[key-b key-c])
  end

  it "never fails the build when the cache cannot be written" do
    allow(described_class).to receive(:directory).and_return(File.join(__FILE__, "cache"))

    expect(described_class.save(key, built)).to be_nil
  end
end
