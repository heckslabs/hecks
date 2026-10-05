require "spec_helper"

# ADR 0081: a query that declares `needs` has the runtime answer the clock port before its filter
# reads the arguments, unless the caller named a value of its own, as a command does.
RSpec.describe "a query that needs a fact" do
  # A fixed clock: the answer must be the bound adapter's, never the real time. It reads
  # 2 days and 100 seconds past the epoch.
  module QueryNeedsFixedClock
    module_function

    def now = (2 * 86_400) + 100
  end

  def declare_pilot
    Hecks.bluebook "QueryNeedsPilot" do
      aggregate "Link" do
        attribute :ref, Ref
        attribute :expires_at, Instant, optional: true
        attribute :day, Day, optional: true
        identified_by :ref

        value_object("Ref")     { attribute :value, String }
        value_object("Instant") { attribute :value, Integer }
        value_object("Day")     { attribute :value, Integer }

        command "Issue" do
          attribute :ref, Ref
          attribute :expires_at, Instant
          attribute :day, Day
          sets :ref
          sets :expires_at
          sets :day
          emits Issued
        end

        query "Expired" do
          attribute :now, Instant
          needs :now
          where("expires_at.value": { lte: :now })
          order_by :ref
        end

        query "IssuedToday" do
          attribute :today, Day
          needs :today
          where("day.value": :today)
          order_by :ref
        end

        # No `needs`: the caller must name the time.
        query "ExpiredAsOf" do
          attribute :now, Instant
          where("expires_at.value": { lte: :now })
          order_by :ref
        end
      end
    end
  end

  def boot_pilot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      declare_pilot
      stub_const("Hecks::Adapters::QueryNeedsClock", QueryNeedsFixedClock)
      Hecks.adapter("QueryNeedsClock") { port "clock" }
      Hecks.hecksagon("QueryNeedsPilot") { QueryNeedsPilot::Link.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot_pilot.tap do |booted|
      [["old", 50, 1], ["mid", 172_900, 2], ["late", 999_999, 2]].each do |ref, expires, day|
        booted.dispatch_flat("QueryNeedsPilot::Link.Issue", ref: { value: ref },
                                                            expires_at: { value: expires }, day: { value: day })
      end
    end
  end

  def refs(rows) = rows.map { |row| row[:ref][:value] }

  it "answers a needed `now` from the bound clock when the caller names none" do
    expect(refs(runtime.query("QueryNeedsPilot::Link.Expired"))).to eq(%w[mid old])
  end

  it "keeps a value the caller names" do
    expect(refs(runtime.query("QueryNeedsPilot::Link.Expired", now: { value: 100 }))).to eq(%w[old])
  end

  it "answers a needed `today` as whole days since the epoch" do
    expect(refs(runtime.query("QueryNeedsPilot::Link.IssuedToday"))).to eq(%w[late mid])
  end

  it "leaves a query without `needs` to its caller: nothing is filled from the clock" do
    expect(refs(runtime.query("QueryNeedsPilot::Link.ExpiredAsOf"))).to eq([])
    expect(refs(runtime.query("QueryNeedsPilot::Link.ExpiredAsOf", now: { value: 172_900 }))).to eq(%w[mid old])
  end

  describe "the builder" do
    def build(&block) = Hecks::Bluebook::DSL::QueryBuilder.build("Ask", &block)

    it "records a declared fact on the query and emits it" do
      query = build do
        attribute :now, Integer
        needs :now
      end

      expect(query.needs).to eq([:now])
      expect(query.to_h[:needs]).to eq([{ fact: "now" }])
    end

    it "leaves a query that needs nothing with its old wire shape" do
      expect(build { attribute :now, Integer }.to_h).not_to have_key(:needs)
    end

    it "refuses a fact the runtime cannot supply" do
      expect { build { needs :weather } }.to raise_error(Hecks::Bluebook::DSL::Malformed, /cannot supply/)
    end

    it "refuses a fact declared twice" do
      expect do
        build do
          attribute :now, Integer
          needs :now
          needs :now
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /twice/)
    end

    it "refuses a need with no attribute to fill" do
      expect { build { needs :now } }.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares no attribute :now/)
    end
  end
end
