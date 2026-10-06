require "hecks"
require "tmpdir"
require "zlib"
require "json"

RSpec.describe Hecks::Adapters::Heki do
  around do |example|
    @dir = Dir.mktmpdir("hecks-heki-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # Booted once to read the static Order IR; mutations go to each example's own tmpdir store.
  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  let(:aggregate) { @aggregate }

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
  end

  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  # A second adapter over the same directory, as a fresh boot would open it.
  def reopened_adapter = described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)

  describe "the adapter contract" do
    it "answers nil for an id it never stored" do
      expect(adapter.find("ghost")).to be_nil
    end

    it "saves and finds" do
      # Both fields are declared on Order, so the codec symbolizes their members on read;
      # an undeclared field's nested keys keep the stored spelling (StateCodec's header).
      adapter.save(instance("p1", name: { value: "Margherita" }, customer_name: { value: "Ada" }))

      found = adapter.find("p1")
      expect([found.id, found[:name].to_h, found[:customer_name].to_h]).to eq(["p1", { value: "Margherita" }, { value: "Ada" }])
    end

    def journalled_names
      File.readlines("#{adapter.path}.journal", chomp: true)
          .map { |line| JSON.parse(line).fetch("state").fetch("name").fetch("value") }
    end

    it "keeps every write and reads the last entry", :aggregate_failures do
      adapter.save(instance("p1", name: { value: "First" }))
      adapter.save(instance("p1", name: { value: "Second" }))

      expect([adapter.count, adapter.find("p1")[:name].to_h]).to eq([1, { value: "Second" }])
      expect(journalled_names).to eq(%w[First Second])
    end

    it "lists what it holds, in id order" do
      adapter.save(instance("p2", name: { value: "Second" }))
      adapter.save(instance("p1", name: { value: "First" }))

      expect(adapter.all.map(&:id)).to eq(["p1", "p2"])
    end

    it "deletes, and says whether there was anything to delete", :aggregate_failures do
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

    it "#project answers a Runtime::Instance on save, like every other adapter", :aggregate_failures do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "p1", state: { name: { value: "Margherita" } })
      projected = adapter.project(entry)

      expect(projected).to be_a(Hecks::Runtime::Instance)
      expect(projected.id).to eq("p1")
    end

    # Saves a record, then deletes it through `append` and `project`; answers the entry and what
    # `project` answered. `append` comes before `project`, as `#delete` does; `#project` alone would
    # let the journalled save entry resurrect the record on the next `read`'s `replay_journal`.
    def project_a_deletion
      adapter.save(instance("p1", name: { value: "Doomed" }))
      delete_entry = Hecks::Ports::Persistence::Entry.new(operation: "delete", id: "p1", state: nil)
      adapter.append(delete_entry)
      [delete_entry, adapter.project(delete_entry)]
    end

    it "#project answers the removed Runtime::Instance on delete, or nil when none was held", :aggregate_failures do
      delete_entry, deleted = project_a_deletion

      expect(deleted).to be_a(Hecks::Runtime::Instance)
      expect(deleted.id).to eq("p1")
      expect(adapter.project(delete_entry)).to be_nil
    end
  end

  describe "crash safety and concurrency" do
    context "when the rename of a snapshot fails" do
      before do
        adapter.save(instance("p1", name: { value: "First" }))
        @original = File.binread(adapter.path)
        allow(File).to receive(:rename).and_raise("boom")
      end

      it "writes the snapshot through a temp file and rename, never in place", :aggregate_failures do
        expect { adapter.save(instance("p2", name: { value: "Second" })) }.to raise_error("boom")
        # The rename never happened, so the snapshot is untouched.
        expect(File.binread(adapter.path)).to eq(@original)
      end

      it "leaves the journal append for a fresh boot to replay", :aggregate_failures do
        expect { adapter.save(instance("p2", name: { value: "Second" })) }.to raise_error("boom")

        # The journal append landed before the snapshot write; a fresh boot replays it.
        expect(reopened_adapter.find("p2")[:name].to_h).to eq(value: "Second")
      end
    end

    it "leaves no temp file behind after a successful save" do
      adapter.save(instance("p1", name: { value: "X" }))

      expect(Dir.glob(File.join(@dir, "*.tmp.*"))).to be_empty
    end

    it "holds a lock file beside the snapshot" do
      adapter.save(instance("p1", name: { value: "X" }))

      expect(File.exist?("#{adapter.path}.lock")).to be true
    end

    context "with forked writers" do
      before { skip "no fork on this platform" unless Process.respond_to?(:fork) }

      def fork_ids = (1..8).to_a

      def write_from_forks
        pids = fork_ids.map do |i|
          fork { reopened_adapter.save(instance("p#{i}", name: { value: "V#{i}" })) }
        end
        pids.each { |pid| Process.waitpid(pid) }
      end

      it "survives concurrent writers without any of them clobbering another's record", :aggregate_failures do
        write_from_forks

        expect(reopened_adapter.all.map(&:id)).to eq(fork_ids.map { |i| "p#{i}" }.sort)
        # Every journal line parses; none was split by a concurrent append.
        expect { reopened_adapter.entries }.not_to raise_error
      end
    end
  end

  describe "#compact! — explicit, opt-in journal compaction" do
    def journal_path = "#{adapter.path}.journal"

    def records_of(store) = store.all.map { |record| [record.id, record[:name].to_h] }

    context "with many writes across several ids and a delete" do
      before do
        (1..5).each do |i|
          3.times { |version| adapter.save(instance("p#{i}", name: { value: "v#{i}.#{version}" })) }
        end
        adapter.delete("p3")
        @expected = records_of(adapter)
      end

      it "holds a journal with every write and the delete", :aggregate_failures do
        expect(File.size(journal_path)).to be > 0
        expect(adapter.entries.length).to eq((5 * 3) + 1) # 3 saves per id + 1 delete
      end

      it "discards the journal", :aggregate_failures do
        adapter.compact!

        expect(adapter.entries).to eq([])
        expect(File.size(journal_path)).to eq(0)
      end

      it "loses no current state" do
        adapter.compact!

        expect(records_of(adapter)).to eq(@expected)
      end

      # A fresh boot replaying the emptied journal must match the pre-compaction state.
      it "lets a fresh boot match the pre-compaction state", :aggregate_failures do
        adapter.compact!

        expect(records_of(reopened_adapter)).to eq(@expected)
        expect(reopened_adapter.find("p3")).to be_nil
      end
    end

    context "when the snapshot rename fails during compaction" do
      before do
        adapter.save(instance("p1", name: { value: "First" }))
        adapter.save(instance("p1", name: { value: "Second" }))
        allow(File).to receive(:rename).and_raise("boom")
      end

      it "writes the snapshot through the same atomic temp-file-plus-rename `write` already uses" do
        expect { adapter.compact! }.to raise_error("boom")
      end

      # No rename means no truncate: the journal stays full and a fresh boot recovers from it.
      it "keeps the journal full, and a fresh boot recovers from it", :aggregate_failures do
        expect { adapter.compact! }.to raise_error("boom")

        expect(File.read(journal_path)).not_to be_empty
        expect(reopened_adapter.find("p1")[:name].to_h).to eq(value: "Second")
      end
    end

    context "when a crash comes between the snapshot write succeeding and the journal truncate running" do
      before do
        adapter.save(instance("p1", name: { value: "First" }))
        adapter.save(instance("p1", name: { value: "Second" }))
        # Only the truncate step crashes; the now-redundant journal lines replay idempotently.
        allow(adapter).to receive(:truncate_journal!).and_raise("simulated crash mid-truncate")
      end

      def crash_compaction = expect { adapter.compact! }.to(raise_error("simulated crash mid-truncate"))

      it "raises the crash, and leaves the journal in place", :aggregate_failures do
        crash_compaction

        expect(File.read(journal_path)).not_to be_empty
      end

      it "recovers correctly on a fresh boot", :aggregate_failures do
        crash_compaction

        expect(reopened_adapter.find("p1")[:name].to_h).to eq(value: "Second")
        expect(reopened_adapter.count).to eq(1)
      end

      # The half-crashed attempt leaves the journal still compactable.
      it "leaves the journal still compactable", :aggregate_failures do
        crash_compaction
        reopened = reopened_adapter
        reopened.compact!

        expect(reopened.entries).to eq([])
        expect(reopened.find("p1")[:name].to_h).to eq(value: "Second")
      end
    end

    it "is a no-op-safe call on a store that was never written to", :aggregate_failures do
      expect { adapter.compact! }.not_to raise_error
      expect(adapter.count).to eq(0)
      expect(adapter.entries).to eq([])
    end

    it "reuses save/delete's own with_lock, not a separate, unsynchronized path" do
      adapter.save(instance("p1", name: { value: "First" }))
      allow(adapter).to receive(:with_lock).and_call_original

      adapter.compact!

      expect(adapter).to have_received(:with_lock).once
    end
  end

  describe "the optional saga-persistence capability (§2/§3/§4)" do
    it "saves a saga instance and reads it back through each_saga" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1",
                        state: "awaiting_credit", memory: { amount: 100 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "awaiting_credit", { amount: 100 }, []]])
    end

    it "replaces on a repeated save for the same (process_manager, correlation)" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "next", memory: { step: 2 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "next", { step: 2 }, []]])
    end

    it "deletes a saga instance" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.delete_saga(process_manager: "Onboarding", correlation: "c1")

      expect(adapter.each_saga.to_a).to eq([])
    end

    it "writes a sibling file, not the aggregate's own store", :aggregate_failures do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})

      expect(File.exist?(File.join(@dir, "hecks_saga_instances.heki"))).to be true
      expect(File.exist?(File.join(@dir, "order.heki"))).to be false
    end

    it "outlives the adapter that wrote it, same as an aggregate's own state" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: { a: 1 })

      reopened = described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
      expect(reopened.each_saga.to_a).to eq([["Onboarding", "c1", "start", { a: 1 }, []]])
    end

    it "replays its journal when a crash leaves no current saga snapshot, same recovery as an aggregate's own store" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "first", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "recovered", memory: {})
      FileUtils.rm_f(File.join(@dir, "hecks_saga_instances.heki"))

      reopened = described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
      expect(reopened.each_saga.to_a).to eq([["Onboarding", "c1", "recovered", {}, []]])
    end

    it "isolates sagas by domain within one shared directory", :aggregate_failures do
      other = described_class.new(aggregate: aggregate, settings: { dir: ".", domain: "OtherDomain" }, root: @dir)
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}, []]])
      expect(other.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}, []]])
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

    it "holds zlib-compressed JSON keyed by id, after the 8-byte header", :aggregate_failures do
      store = JSON.parse(Zlib::Inflate.inflate(bytes[8..]))

      expect(store.keys).to eq(%w[p1 p2])
      expect(store["p1"]["name"]).to eq({ "value" => "Margherita" })
    end

    # Starts the store over, then writes the same two records in the opposite order.
    def rewrite_in_reverse_order
      FileUtils.rm_f(File.join(@dir, "order.heki"))
      FileUtils.rm_f(File.join(@dir, "order.heki.journal"))
      rewritten = reopened_adapter
      rewritten.save(instance("p2", name: { value: "Marinara" }))
      rewritten.save(instance("p1", name: { value: "Margherita" }))
    end

    it "writes ids in sorted order, so the same records give the same bytes" do
      first = bytes
      rewrite_in_reverse_order

      expect(File.binread(File.join(@dir, "order.heki"))).to eq(first)
    end
  end

  describe "resolve_path" do
    # `dir: :default` (a bare Symbol) must behave like no `dir` setting; `File.join` raises on it.
    it "treats a bare :default Symbol the same as no dir setting at all", :aggregate_failures do
      defaulted = described_class.new(aggregate: aggregate, settings: { dir: :default }, root: @dir)
      absent    = described_class.new(aggregate: aggregate, settings: {}, root: @dir)

      expect(defaulted.path).to eq(absent.path)
      expect(defaulted.path).to eq(File.join(@dir, "data", "order.heki"))
    end

    it "still honors a real declared string path" do
      adapter = described_class.new(aggregate: aggregate, settings: { dir: "custom" }, root: @dir)

      expect(adapter.path).to eq(File.join(@dir, "custom", "order.heki"))
    end

    it "still falls back to \"data\" when dir is truly absent" do
      adapter = described_class.new(aggregate: aggregate, settings: {}, root: @dir)

      expect(adapter.path).to eq(File.join(@dir, "data", "order.heki"))
    end
  end

  describe "refusing what it cannot read" do
    def write_raw(contents)
      File.binwrite(File.join(@dir, "order.heki"), contents)
      described_class.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)
    end

    it "refuses a file that is not heki" do
      expect { write_raw("NOPE#{[0].pack("N")}").count }
        .to raise_error(described_class::Malformed, /bad magic/)
    end

    it "refuses a file too short to hold a header" do
      expect { write_raw("HEK").count }
        .to raise_error(described_class::Malformed, /too short/)
    end

    it "refuses a payload that is not zlib" do
      expect { write_raw("HEKI#{[1].pack("N")}not compressed").count }
        .to raise_error(described_class::Malformed, /zlib error/)
    end

    it "reads an absent file as an empty store" do
      expect(adapter.count).to eq(0)
    end
  end
end
