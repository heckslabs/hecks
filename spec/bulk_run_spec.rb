require "spec_helper"
require "tmpdir"
require "hecks/fuzzing"

# A bulk run (ADR 0125) sends one command to every row of one query and keeps each row's outcome
# on a `Bulk::BulkRun`. Banking attaches the Bulk bluebook; each example boots a fresh copy of it,
# bound to Memory or to SQLite, with the real adapters answering the ports.
RSpec.describe "a bulk run" do
  around do |example|
    Dir.mktmpdir("bulk-run") do |tmp|
      @tmp = tmp
      Hecks::Runtime::AdapterLookup.standing_in(nil) { example.run }
    end
  end

  # Boots a copy of Banking bound to `adapter` and opens three accounts for one customer.
  def boot(adapter = :memory)
    copy = File.join(@tmp, "banking")
    Hecks::Fuzzing::IsolatedBoot.copy_dereferencing(File.join(InMemoryDomain::ROOT, "examples/banking"), copy)
    Hecks::Fuzzing::IsolatedBoot.rebind!(copy, adapter, database: nil, schema: nil, scratch: {})
    @runtime = Hecks.boot(copy, environment: nil)
    open_accounts(%w[A-1 A-2 A-3])
  end

  def open_accounts(numbers)
    person = { name: { given: "A", family: "Customer" }, email: { address: "a@example.com" } }
    @runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "C-1" }, **person)
    numbers.each do |number|
      @runtime.dispatch_flat("Banking::Account.Open", customer: "C-1", number: { value: number },
                                                       kind: { name: "current" }, daily_limit: { cents: 1_000 })
    end
  end

  def freeze(number) = @runtime.dispatch_flat("Banking::Account.FreezeAccount", account: number)

  def statuses = @runtime.query("Banking::Account.Reachable").to_h { |row| [row[:id], row[:status]] }

  # Requests a run the way the CLI and MCP do, by dispatching `Bulk::BulkRun.Request`.
  def request(run, over:, verb: "Banking::Account.FreezeAccount", arguments: [])
    @runtime.dispatch_flat("Bulk::BulkRun.Request", run: { value: run }, verb: { value: verb },
                                                    over: { value: over }, arguments: arguments)
    @runtime.query("Bulk::BulkRun.Outcome", run: { value: run }).first
  end

  def outcomes(record) = record[:results].map(&:to_h)

  def refused_by_frozen = { outcome: "refused", reason: /moves it only from "open"/ }

  # Boots Banking with A-2 already frozen, so a FreezeAccount sent to it refuses.
  def boot_with_a_frozen_row(adapter = :memory)
    boot(adapter)
    freeze("A-2")
  end

  def a2_refused
    [{ row: "A-1", outcome: "delivered" }, a_hash_including(row: "A-2", **refused_by_frozen),
     { row: "A-3", outcome: "delivered" }]
  end

  def teller_refusal = "FreezeAccount refused — role: Compliance officer, and the caller stated Teller"

  it "keeps one outcome per row, sending to every row even after one refuses", :aggregate_failures do
    boot_with_a_frozen_row
    record = request("r1", over: "Banking::Account.Reachable")
    expect(record[:status]).to eq("swept")
    expect(outcomes(record)).to match(a2_refused)
  end

  it "runs the query with the arguments it was given, read as the query declares them" do
    boot
    arguments = [{ key: "reference", value: "C-1" }]
    record = request("r2", over: "Banking::Account.OpenForCustomer", arguments: arguments)
    expect(outcomes(record).map { |row| row[:row] }).to eq(%w[A-1 A-2 A-3])
  end

  it "sends each row with the authority of whoever asked, so a command's role is checked per row" do
    boot
    record = Hecks.as_caller(role: "Teller") { request("r7", over: "Banking::Account.Open") }
    expect(outcomes(record).map { |row| row[:reason] }.uniq).to eq([teller_refusal])
  end

  describe "through the CLI" do
    it "requests a run of the attached bluebook by its word, as `banking bulk bulk_run.request!`" do
      boot
      argv = %w[bulk bulk_run.request! run.value=c1 verb.value=Banking::Account.FreezeAccount
                over.value=Banking::Account.Open]
      Hecks::Adapters::Driving::CliRunner.call(runtime: @runtime, argv: argv, program: "banking")
      expect(statuses.values.uniq).to eq(["frozen"])
    end
  end

  describe "through MCP" do
    # The storehouse call MCP's `dispatch` tool makes, naming the attached bluebook by its word.
    def mcp_request(run)
      args = { run: { value: run }, verb: { value: "Banking::Account.FreezeAccount" },
               over: { value: "Banking::Account.Open" } }
      Hecks::Storehouse.dispatch(runtime: @runtime, command: "bulk bulk_run.request", summary: "spec", args: args)
    end

    it "requests a run of the attached bluebook and answers it as every row left it", :aggregate_failures do
      boot
      answer = mcp_request("m1")
      expect(answer[:state][:status]).to eq("swept")
      expect(statuses.values.uniq).to eq(["frozen"])
    end
  end

  describe "from Ruby" do
    it "runs a non-creating command over what a query method answered", :aggregate_failures do
      boot
      run = Account.freeze_account!(over: Account.open_for_customer(reference: "C-1"))
      expect(run.status).to eq("swept")
      expect(statuses.values.uniq).to eq(["frozen"])
    end

    it "refuses a list that names no query" do
      boot
      expect { Account.freeze_account!(over: Account.open.to_a) }.to raise_error(ArgumentError, /names no query to run/)
    end
  end
end
