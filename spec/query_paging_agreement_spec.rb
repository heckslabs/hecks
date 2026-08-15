
require "spec_helper"

# LIMIT AND OFFSET TOGETHER, ON EVERY ENGINE, ANSWERING THE SAME.
#
# `Ports::Query::InMemory` applied `limit` before `offset` — take n, then
# drop m — where `SqlQueryBuilder` emits `LIMIT n OFFSET m`, which SQL
# reads the other way round. So one declaration meant two different
# things depending on where the aggregate happened to be stored, and
# neither engine refused: a short page is indistinguishable from a page
# that genuinely ran out of rows.
#
# The existing adapter-agreement gate did not catch it because nothing in
# the corpus declares BOTH words on one query — banking's `Overdrawn` has
# a limit and no offset, and no query anywhere has an offset with a
# limit. This is that missing case, written as the arithmetic rather than
# as a comparison, so it holds even for an engine nobody has added yet.
RSpec.describe "limit and offset on one query" do
  def boot_pages
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Paging" do
        aggregate "Ticket" do
          attribute :number, Number

          identified_by :number

          value_object("Number") { attribute :value, String }

          command "Draw" do
            attribute :number, Number
            sets :number, to: :number
            emits "TicketDrawn"
          end

          query "All" do
            order_by :number
          end

          # PAGE TWO, written the way anybody pages: skip a page, take a
          # page. The bug made this answer nothing at all.
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

      Hecks.hecksagon("Paging") { ::Paging::Ticket.persisted_by("Memory") }
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot_pages.tap do |bound|
      %w[t-1 t-2 t-3 t-4 t-5].each do |number|
        bound.dispatch("Paging::Ticket.Draw", number: { value: number })
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

  # THE ARITHMETIC, not a fixture — paging is only correct if the pages
  # reassemble into the whole, in order, with nothing dropped or seen
  # twice. Stated this way it stays true for any page size.
  it "reassembles every row exactly once across consecutive pages" do
    all = numbers("All")
    # AfterFirst is rows 2-3; SkipTwo starts at row 3, so one row of it
    # is the overlap and the rest is the tail.
    expect(numbers("AfterFirst") + numbers("SkipTwo").drop(1)).to eq(all.drop(1))
    expect(numbers("SecondPage")).to eq(all[2, 2])
  end
end
