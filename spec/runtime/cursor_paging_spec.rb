require "spec_helper"
require "tmpdir"
require "hecks/fuzzing"

# `cursor` pages a query by its order field and identity (ADR 0130). Banking's `OpenPaged` orders
# open accounts by number with a page of 25, so twenty-seven accounts take two pages; each example
# boots a fresh copy bound to Memory or to SQLite.
RSpec.describe "a cursor query" do
  def query_name = "Banking::Account.OpenPaged"

  def numbers = (1..27).map { |n| format("A-%02d", n) }

  around do |example|
    Dir.mktmpdir("cursor-paging") do |tmp|
      @tmp = tmp
      Hecks::Runtime::AdapterLookup.standing_in(nil) { example.run }
    end
  end

  def boot(adapter)
    copy = File.join(@tmp, "banking")
    Hecks::Fuzzing::IsolatedBoot.copy_dereferencing(File.join(InMemoryDomain::ROOT, "examples/banking"), copy)
    Hecks::Fuzzing::IsolatedBoot.rebind!(copy, adapter, database: nil, schema: nil, scratch: {})
    @runtime = Hecks.boot(copy, environment: nil)
    open_accounts
  end

  def open_accounts
    person = { name: { given: "A", family: "Customer" }, email: { address: "a@example.com" } }
    @runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "C-1" }, **person)
    numbers.shuffle(random: Random.new(7)).each { |number| open_account(number) }
  end

  def open_account(number)
    @runtime.dispatch_flat("Banking::Account.Open", customer: "C-1", number: { value: number },
                                                     kind: { name: "current" }, daily_limit: { cents: 1_000 })
  end

  def numbers_of(rows) = rows.map { |row| row[:number][:value] }

  def first_page = @runtime.query_page(query_name)

  def second_page = @runtime.query_page(query_name, after: first_page[:after])

  shared_examples "pages by cursor" do
    it "answers the page size, then the rest", :aggregate_failures do
      boot(adapter)
      expect(numbers_of(first_page[:rows])).to eq(numbers.first(25))
      expect(numbers_of(second_page[:rows])).to eq(numbers.last(2))
    end

    it "gives no next position on the last page", :aggregate_failures do
      boot(adapter)
      expect(first_page[:after]).to be_a(String)
      expect(second_page[:after]).to be_nil
    end

    it "answers the same rows through plain `query` with `after`" do
      boot(adapter)
      expect(numbers_of(@runtime.query(query_name, after: first_page[:after]))).to eq(numbers.last(2))
    end

    it "answers an empty last page after the final row" do
      boot(adapter)
      token = Hecks::Ports::Query::Cursor.encode("A-99", "A-99")
      expect(@runtime.query_page(query_name, after: token)).to eq(rows: [], after: nil)
    end

    it "refuses a position the query did not hand out" do
      boot(adapter)
      expect { @runtime.query_page(query_name, after: "nonsense") }.to raise_error(Hecks::Ports::Query::Cursor::Invalid)
    end

    it "is swept in full by a bulk run, not only its first page" do
      boot(adapter)
      @runtime.dispatch_flat("Bulk::BulkRun.Request", run: { value: "r1" }, verb: { value: "Banking::Account.FreezeAccount" },
                                                      over: { value: query_name }, arguments: [])
      expect(@runtime.query("Banking::Account.Open")).to be_empty
    end
  end

  describe "on Memory" do
    let(:adapter) { :memory }

    it_behaves_like "pages by cursor"
  end

  describe "on SQLite" do
    let(:adapter) { :sqlite }

    it_behaves_like "pages by cursor"
  end

  it "refuses a query without a cursor asked for a page" do
    boot(:memory)
    expect { @runtime.query_page("Banking::Account.Open") }.to raise_error(ArgumentError, /declares no cursor/)
  end
end
