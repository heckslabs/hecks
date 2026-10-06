require "spec_helper"

# Limit and offset together answer the same on every engine: skip m rows, then take n,
# as SQL's LIMIT n OFFSET m reads. Stated as arithmetic so it holds for any new engine.
RSpec.describe "limit and offset on one query" do
  PAGING_BLUEBOOK = proc do
    aggregate "Ticket" do
      attribute :number, Number

      identified_by :number

      value_object("Number") { attribute :value, String }

      command "Draw" do
        attribute :number, Number
        sets :number
        emits "TicketDrawn"
      end

      query "All" do
        order_by :number
      end

      query "SecondPage" do
        order_by :number
        limit 2
        offset 2
      end

      query "AfterFirst" do
        order_by :number
        limit 2
        offset 1
      end

      query "SkipTwo" do
        order_by :number
        offset 2
      end
    end
  end

  def boot_pages
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |port| Kernel.load(port) }

      Hecks.bluebook("Paging", &PAGING_BLUEBOOK)
      Hecks.hecksagon("Paging") { Paging::Ticket.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot_pages.tap do |bound|
      %w[t-1 t-2 t-3 t-4 t-5].each do |number|
        bound.dispatch_flat("Paging::Ticket.Draw", number: { value: number })
      end
    end
  end

  def numbers(query) = runtime.query("Paging::Ticket.#{query}").map { |row| row[:number][:value] }

  it "skips before it takes, the way SQL's own LIMIT n OFFSET m reads" do
    expect(numbers("AfterFirst")).to eq(%w[t-2 t-3])
  end

  it "answers a second page rather than nothing" do
    expect(numbers("SecondPage")).to eq(%w[t-3 t-4])
  end

  it "leaves an offset with no limit running to the end" do
    expect(numbers("SkipTwo")).to eq(%w[t-3 t-4 t-5])
  end

  # Pages must reassemble into the whole, in order, with nothing dropped or repeated.
  it "reassembles every row exactly once across consecutive pages", :aggregate_failures do
    all = numbers("All")
    # AfterFirst is rows 2-3; SkipTwo starts at row 3, so one row of it
    # is the overlap and the rest is the tail.
    expect(numbers("AfterFirst") + numbers("SkipTwo").drop(1)).to eq(all.drop(1))
    expect(numbers("SecondPage")).to eq(all[2, 2])
  end
end
