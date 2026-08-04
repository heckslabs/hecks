require "hecksagain"
require "tmpdir"
require "zlib"
require "json"

RSpec.describe Hecksagain::Adapters::Heki do
  around do |example|
    @dir = Dir.mktmpdir("hecksagain-heki-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:aggregate) do
    boot_in_memory.registry.bluebook("Pizzas").aggregate("Order")
  end

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
  end

  def instance(id, **fields)
    built = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecksagain::Runtime::Value.for(aggregate, name, value) }
    built
  end

  describe "the adapter contract" do
    it "answers nil for an id it never stored" do
      expect(adapter.find("ghost")).to be_nil
    end

    it "saves and finds" do
      adapter.save(instance("p1", name: { value: "Margherita" }, price_cents: { cents: 1200 }))

      found = adapter.find("p1")
      expect([found.id, found[:name].to_h, found[:price_cents].to_h]).to eq(["p1", { value: "Margherita" }, { cents: 1200 }])
    end

    it "keeps every write and reads the last entry" do
      adapter.save(instance("p1", name: { value: "First" }))
      adapter.save(instance("p1", name: { value: "Second" }))

      expect(adapter.count).to eq(1)
      expect(adapter.find("p1")[:name].to_h).to eq(value: "Second")
      entries = File.readlines("#{adapter.path}.journal", chomp: true).map { |line| JSON.parse(line) }
      expect(entries.map { |entry| entry.fetch("state").fetch("name").fetch("value") }).to eq(%w[First Second])
    end

    it "lists what it holds, in id order" do
      adapter.save(instance("p2", name: { value: "Second" }))
      adapter.save(instance("p1", name: { value: "First" }))

      expect(adapter.all.map(&:id)).to eq(["p1", "p2"])
    end

    it "deletes, and says whether there was anything to delete" do
      adapter.save(instance("p1", name: { value: "Doomed" }))

      expect(adapter.delete("p1")).to be true
      expect(adapter.delete("p1")).to be false
      expect(adapter.count).to eq(0)
    end

    it "outlives the adapter that wrote it" do
      adapter.save(instance("p1", name: { value: "Persisted" }))

      reopened = described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
      expect(reopened.find("p1")[:name].to_h).to eq(value: "Persisted")
    end

    it "replays its journal when a crash leaves no current snapshot" do
      adapter.save(instance("p1", name: { value: "First" }))
      adapter.save(instance("p1", name: { value: "Recovered" }))
      FileUtils.rm_f(adapter.path)

      reopened = described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
      expect(reopened.find("p1")[:name].to_h).to eq(value: "Recovered")
    end

    it "writes one store per aggregate, named for it" do
      adapter.save(instance("p1", name: { value: "Named" }))

      expect(File.exist?(File.join(@dir, "order.heki"))).to be true
    end
  end

  describe "the file format" do
    let(:bytes) do
      adapter.save(instance("p1", name: { value: "Margherita" }))
      adapter.save(instance("p2", name: { value: "Marinara" }))
      File.binread(File.join(@dir, "order.heki"))
    end

    it "opens with the HEKI magic" do
      expect(bytes[0, 4]).to eq("HEKI")
    end

    it "carries the record count as a big-endian u32" do
      expect(bytes[4, 4].unpack1("N")).to eq(2)
    end

    it "holds zlib-compressed JSON keyed by id, after the 8-byte header" do
      store = JSON.parse(Zlib::Inflate.inflate(bytes[8..]))

      expect(store.keys).to eq(%w[p1 p2])
      expect(store["p1"]["name"]).to eq({ "value" => "Margherita" })
    end

    it "writes ids in sorted order, so the same records give the same bytes" do
      first = bytes

      FileUtils.rm_f(File.join(@dir, "order.heki"))
      FileUtils.rm_f(File.join(@dir, "order.heki.journal"))
      rewritten = described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
      rewritten.save(instance("p2", name: { value: "Marinara" }))
      rewritten.save(instance("p1", name: { value: "Margherita" }))

      expect(File.binread(File.join(@dir, "order.heki"))).to eq(first)
    end
  end

  describe "refusing what it cannot read" do
    def write_raw(contents)
      File.binwrite(File.join(@dir, "order.heki"), contents)
      described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
    end

    it "refuses a file that is not heki" do
      expect { write_raw("NOPE" + [0].pack("N")).count }
        .to raise_error(described_class::Malformed, /bad magic/)
    end

    it "refuses a file too short to hold a header" do
      expect { write_raw("HEK").count }
        .to raise_error(described_class::Malformed, /too short/)
    end

    it "refuses a payload that is not zlib" do
      expect { write_raw("HEKI" + [1].pack("N") + "not compressed").count }
        .to raise_error(described_class::Malformed, /zlib error/)
    end

    it "reads an absent file as an empty store" do
      expect(adapter.count).to eq(0)
    end
  end
end
