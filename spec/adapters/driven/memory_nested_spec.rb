require "spec_helper"
require "tmpdir"
require "fileutils"

# A Memory-backed aggregate whose growing data lives inside one value object: the cost of a save
# follows what changed, not how large the value object is, and sharing the unchanged parts between
# journal entries and records never lets a caller reach journalled state.
RSpec.describe "Memory with a large nested value object" do
  NESTED_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Ledger" do
      vision "An aggregate whose state carries one large nested value object."
      supporting

      aggregate "Book" do
        description "A book holding its entries inside a single Journal value object."
        attribute :label, Label
        attribute :tick, Tick
        attribute :journal, Journal
        attribute :archive, Archive
        identified_by :label

        value_object "Label" do
          attribute :value, String
        end

        value_object "Tick" do
          attribute :value, Integer, default: 0
        end

        value_object "Cell" do
          attribute :column, Integer
          attribute :row, Integer
        end

        value_object "Journal" do
          attribute :note, String
          attribute :cells, list_of(Cell)
        end

        value_object "Archive" do
          attribute :journal, Journal
        end

        command "Open" do
          goal "Open a book"
          attribute :label, Label
        end

        command "Fill" do
          goal "Replace the journal"
          reference_to Book
          attribute :journal, Journal
          sets :journal
          emits "Filled"
        end

        command "Shelve" do
          goal "Replace the archive"
          reference_to Book
          attribute :archive, Archive
          sets :archive
          emits "Shelved"
        end

        command "Advance" do
          goal "One more tick; the journal is untouched"
          reference_to Book
          sets :tick, increment: { value: 1 }
          emits "Advanced"
        end
      end
    end
  RUBY

  around do |example|
    @dir = Dir.mktmpdir("memory-nested")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    File.write(File.join(@dir, "bluebook/ledger.bluebook"), NESTED_BLUEBOOK)
    File.write(File.join(@dir, "bluebook/ledger.hecksagon"),
               %(Hecks.hecksagon "Ledger" do\n  Ledger::Book.persisted_by("Memory")\nend\n))
    example.run
  ensure
    FileUtils.rm_rf(@dir)
  end

  let(:runtime) { Hecks.boot(@dir, install_doors: false) }
  let(:aggregate) { runtime.registry.bluebook("Ledger").aggregate("Book") }
  let(:repository) { runtime.registry.repository("Ledger", aggregate) }
  let(:codec) { Hecks::Ports::Persistence::StateCodec }

  def cells(count) = Array.new(count) { |i| { column: i % 8, row: i / 8 } }

  def open_book(label = "b", size: 20)
    runtime.dispatch_flat("Ledger::Book.Open", label: { value: label })
    runtime.dispatch_flat("Ledger::Book.Fill", label: label, journal: { note: "n", cells: cells(size) })
  end

  def advance(label = "b") = runtime.dispatch_flat("Ledger::Book.Advance", label: label)

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def allocations_per_step(count, label = "b")
    before = GC.stat(:total_allocated_objects)
    count.times { advance(label) }
    (GC.stat(:total_allocated_objects) - before) / count.to_f
  end

  def seconds_per_step(count, label)
    started = clock
    count.times { advance(label) }
    (clock - started) / count
  end

  def build_journal(journal_cells)
    Hecks::Runtime::Value.build(aggregate.value_object("Journal"), { note: "n", cells: journal_cells }, aggregate)
  end

  # Objects allocated by saving `journal` as book `g<count>`.
  def allocations_for_save(adapter, count, journal)
    state = { label: { value: "g#{count}" }, journal: journal }
    before = GC.stat(:total_allocated_objects)
    adapter.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "g#{count}", state: state))
    GC.stat(:total_allocated_objects) - before
  end

  # The allocations of the third save of a journal that starts at `count` cells and gains one
  # per save.
  def allocations_of_third_gain(adapter, count)
    held = build_journal(cells(count))
    Array.new(3) do |step|
      held = build_journal(held[:cells] + [{ column: step, row: 9 }])
      allocations_for_save(adapter, count, held)
    end.last
  end

  # How much slower a step is with 200 cells than with 20, for the books of attempt `attempt`.
  def large_to_small_ratio(attempt)
    open_book("s#{attempt}", size: 20)
    open_book("l#{attempt}", size: 200)
    advance("s#{attempt}")
    advance("l#{attempt}")
    seconds_per_step(5, "l#{attempt}") / seconds_per_step(5, "s#{attempt}")
  end

  describe "growth" do
    it "allocates about the same per step with 200 cells in the value object as with 20" do
      open_book("small", size: 20)
      open_book("large", size: 200)
      advance("small")
      advance("large")

      expect(allocations_per_step(5, "large")).to be < allocations_per_step(5, "small") * 2
    end

    it "takes about the same time per step with 200 cells in the value object as with 20" do
      ratios = Array.new(2) { |attempt| large_to_small_ratio(attempt) }

      expect(ratios.min).to be < 3
    end

    it "saves a journal that gains one cell per save for the cost of the new cell" do
      adapter = Hecks::Adapters::Memory.new(aggregate: aggregate)
      small = allocations_of_third_gain(adapter, 20)
      large = allocations_of_third_gain(adapter, 200)

      expect(large).to be < small * 2
    end
  end

  describe "sharing between journal entries" do
    before do
      open_book
      3.times { advance }
    end

    it "journals an unchanged value object once, as one frozen node shared by every later entry", :aggregate_failures do
      saves = repository.entries.select { |entry| entry.id == "b" }.last(3)
      journal = saves.first.state[:journal]

      expect(saves.last.state[:journal]).to equal(journal)
      expect(journal).to be_frozen
      expect(Hecks::Freezer.deeply_frozen?(journal)).to be(true)
    end

    it "journals the same shape a durable adapter would read back", :aggregate_failures do
      journalled = repository.entries.last.state
      durable = codec.copy(aggregate, repository.find("b").state)

      expect([journalled, journalled.keys]).to eq([durable, durable.keys])
      expect(journalled[:journal]).to be_a(Hash).and(have_attributes(keys: %i[note cells]))
      expect(journalled[:journal][:cells].size).to eq(20)
    end

    it "journals a value object nested in another value object as the codec would", :aggregate_failures do
      runtime.dispatch_flat("Ledger::Book.Shelve", label: "b", archive: { journal: { note: "a", cells: cells(3) } })
      advance
      entry = repository.entries.last

      expect(entry.state).to eq(codec.copy(aggregate, repository.find("b").state))
      expect(entry.state[:archive]).to eq(journal: { note: "a", cells: cells(3) })
    end
  end

  describe "aliasing" do
    before do
      open_book
      2.times { advance }
    end

    it "refuses an in-place change to a journalled value object", :aggregate_failures do
      journal = repository.entries.last.state[:journal]

      expect { journal[:note] = "changed" }.to raise_error(FrozenError)
      expect { journal[:cells] << {} }.to raise_error(FrozenError)
      expect { journal[:cells].first[:row] = 99 }.to raise_error(FrozenError)
    end

    it "leaves the journal alone when a returned instance's state is changed" do
      before = Marshal.load(Marshal.dump(repository.entries.map(&:state)))
      record = repository.find("b")

      record.state[:journal] = :changed
      record.state[:tick] = :changed

      expect(repository.entries.map(&:state)).to eq(before)
    end

    def same_nodes(live, held) = live[:cells].zip(held[:cells]).map { |live_cell, held_cell| live_cell.equal?(held_cell) }

    it "shares no node between a record and the journal", :aggregate_failures do
      live = repository.find("b").state[:journal]
      journalled = repository.entries.last.state[:journal]

      expect(live).to be_a(Hecks::Runtime::Value)
      expect(live).not_to equal(journalled)
      expect(same_nodes(live, journalled)).to all(be(false))
    end

    it "hands every reader the same frozen value object, never one that reaches the journal", :aggregate_failures do
      first = repository.find("b").state[:journal]

      expect(repository.find("b").state[:journal]).to equal(first)
      expect(first).to be_frozen
      expect { first[:cells] << {} }.to raise_error(FrozenError)
    end
  end

  describe "values a caller may still change" do
    let(:elements) { Hecks::Adapters::Memory::SharedElements.new(aggregate) }

    def plain_journal = { note: "n", cells: [{ column: 0, row: 0 }] }

    # Copies a state holding a plain Hash journal, then changes that Hash; answers the copy and
    # the state.
    def copy_then_change
      journal = plain_journal
      state = { label: { value: "m" }, journal: journal }
      copied = elements.journal_state(state)
      journal[:cells].first[:row] = 7
      journal[:note] = "changed"
      [copied, state]
    end

    it "copies a plain Hash whole and shares nothing with it", :aggregate_failures do
      copied, state = copy_then_change

      expect(copied).to eq(codec.copy(aggregate, state.merge(journal: plain_journal)))
      expect(copied[:journal]).not_to be_frozen
      expect(copied[:journal][:cells].first).not_to be_frozen
    end

    it "copies an unhydrated Hash value object again for every save" do
      state = { label: { value: "m" }, journal: { note: "n", cells: [] } }

      expect(elements.journal_state(state)[:journal]).not_to equal(elements.journal_state(state)[:journal])
    end
  end

  describe "replay" do
    def book_with_archive_and_ticks
      open_book
      runtime.dispatch_flat("Ledger::Book.Shelve", label: "b", archive: { journal: { note: "a", cells: cells(2) } })
      4.times { advance }
    end

    def replayed_record
      replica = Hecks::Adapters::Memory.new(aggregate: aggregate)
      repository.entries.each { |entry| replica.project(entry) }
      replica.find("b")
    end

    def reset_and_reopen_book
      open_book
      advance
      repository.reset!
      open_book
      advance
    end

    it "rebuilds identical records from the journal", :aggregate_failures do
      book_with_archive_and_ticks
      held = repository.find("b")
      rebuilt = replayed_record

      expect(Hecks::Runtime::Value.materialize(rebuilt.to_h)).to eq(Hecks::Runtime::Value.materialize(held.to_h))
      expect(rebuilt.state.keys).to eq(held.state.keys)
    end

    it "gives a reset adapter nothing to reuse and still saves correctly", :aggregate_failures do
      reset_and_reopen_book

      expect(repository.find("b")[:journal][:cells].size).to eq(20)
      expect(repository.entries.size).to eq(3)
    end
  end

  describe "concurrency" do
    it "saves from several threads without losing a value object", :aggregate_failures do
      open_book
      threads = Array.new(4) { Thread.new { 5.times { advance } } }
      threads.each(&:join)

      expect(repository.find("b")[:journal][:cells].size).to eq(20)
      expect(repository.entries.last.state[:journal][:cells].size).to eq(20)
    end
  end
end
