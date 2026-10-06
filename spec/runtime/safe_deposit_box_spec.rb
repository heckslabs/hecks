require "spec_helper"

RSpec.describe "a composite-identified aggregate with two entities" do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_banking }

  def register_customer(reference, given, family, email)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: reference },
                          name: { given: given, family: family }, email: { address: email })
  end

  def rent(customer, branch, number, size)
    runtime.dispatch_flat("Banking::SafeDepositBox.Rent", customer: customer, branch_code: { value: branch },
                          box_number: { value: number }, size: { value: size })
  end

  def rented_box
    register_customer("c", "A", "Customer", "a@example.com")
    rent("c", "DOWNTOWN", 12, "medium")
  end

  # Runs a SafeDepositBox command against the DOWNTOWN:12 box.
  def box_command(verb, **facts)
    box_identity = { branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 } }
    runtime.dispatch_flat("Banking::SafeDepositBox.#{verb}", **box_identity, **facts)
  end

  def log_visit(sequence = 1, date = "2026-01-05")
    box_command("LogVisit", date: { value: date }, sequence: { value: sequence })
  end

  def issue_key = box_command("IssueKey", serial: { value: "KEY-1" })

  def return_key = box_command("KeyIssuance.Return", serial: { value: "KEY-1" })

  def downtown_box = Banking::SafeDepositBox.find("DOWNTOWN:12")

  def rented_ids(branch) = runtime.query("Banking::SafeDepositBox.Rented", branch_code: branch).map { |row| row[:id] }

  describe "its declared shape" do
    let(:box) { runtime.registry.bluebook("Banking").aggregate("SafeDepositBox") }

    it "accepts a customer identity fact", :aggregate_failures do
      rent_command = box.command("Rent")

      expect(box.attribute(:customer).relationship).to eq("belongs_to")
      # Redeclaring `attribute :customer, CustomerNumber` on `Rent` would shadow the aggregate's
      # `belongs_to Customer` Reference, so a `given("customer is active")` guard could not read it.
      expect([rent_command.attribute(:customer).type.to_s, rent_command.attribute(:customer).reference?])
        .to eq(["Reference<Customer>", true])
    end

    it "stores the declared relationship" do
      rented_box

      expect(downtown_box[:customer]).to eq("c")
    end
  end

  it "refuses Rent for a suspended customer, and accepts it for an active one (#278)", :aggregate_failures do
    register_customer("active", "A", "One", "a@example.com")
    register_customer("flagged", "B", "Two", "b@example.com")
    runtime.dispatch_flat("Banking::Customer.Suspend", reference: "flagged", standing: { value: "flagged" })

    expect { rent("active", "DOWNTOWN", 1, "small") }.not_to raise_error
    expect { rent("flagged", "DOWNTOWN", 2, "small") }.to raise_error(Hecks::Runtime::GivenNotMet, /customer is active/)
  end

  it "is born at the join of its two identity paths", :aggregate_failures do
    rented_box

    box = downtown_box
    expect(box.branch_code.to_h).to eq(value: "DOWNTOWN")
    expect(box.box_number.to_h).to  eq(value: 12)
    expect(box.status).to eq("rented")
  end

  it "logs a composite-identified entity, appended by its own two-path identity", :aggregate_failures do
    rented_box
    [1, 2].each { |sequence| log_visit(sequence) }

    visits = downtown_box.visits
    expect(visits.map { |v| v[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
    expect(visits.map { |v| v[:state] }).to eq(%w[logged logged])
  end

  it "addresses the composite entity through the parent's composite identity" do
    rented_box
    log_visit
    box_command("Visit.Annotate", date: { value: "2026-01-05" }, sequence: { value: 1 }, note: { text: "Flagged" })

    expect(downtown_box.visits.first[:note].to_h).to eq(text: "Flagged")
  end

  it "carries a single-identified entity beside a composite one on the same head", :aggregate_failures do
    rented_box
    issue_key

    key = downtown_box.keys.first
    expect(key[:serial].to_h).to eq(value: "KEY-1")
    expect(key[:status]).to eq("issued")
  end

  it "returns a single-identified entity beside a composite one on the same head" do
    rented_box
    issue_key
    return_key

    expect(downtown_box.keys.first[:status]).to eq("returned")
  end

  it "refuses to log a visit against a box that is not rented" do
    rented_box
    box_command("Surrender")

    expect { log_visit }.to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "rented"/)
  end

  it "refuses to return a key that is not issued" do
    rented_box
    issue_key
    return_key

    expect { return_key }.to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "issued"/)
  end

  it "announces two facts from one dispatch", :aggregate_failures do
    rented_box
    box_command("Surrender")

    expect(runtime.events.map(&:name)).to include("BoxSurrendered", "KeyReturnDue")
    expect(downtown_box.status).to eq("vacant")
  end

  it "refuses a second surrender" do
    rented_box
    box_command("Surrender")

    expect { box_command("Surrender") }.to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "rented"/)
  end

  it "answers a query with the closed-set attribute the inline shorthand declared", :aggregate_failures do
    rented_box

    rows = runtime.query("Banking::SafeDepositBox.Rented", branch_code: "DOWNTOWN")
    expect(rows.map { |row| row[:id] }).to eq(["DOWNTOWN:12"])
    expect(rows.first[:size].to_h).to eq(value: "medium")
  end

  it "refuses a second LogVisit that collides on the composite date+sequence identity", :aggregate_failures do
    rented_box
    log_visit

    expect { log_visit }.to raise_error(Hecks::Runtime::AlreadyExists, /Visit.*already exists/)
    # A refused second write leaves the first exactly as it was.
    expect(downtown_box.visits.size).to eq(1)
  end

  it "refuses a second IssueKey that collides on the single serial identity", :aggregate_failures do
    rented_box
    issue_key

    expect { issue_key }.to raise_error(Hecks::Runtime::AlreadyExists, /KeyIssuance.*already exists/)
    expect(downtown_box.keys.size).to eq(1)
  end

  it "does not spuriously flag an auto-minted entity list — two visits on different days both land" do
    rented_box
    log_visit(1, "2026-01-05")
    log_visit(1, "2026-01-06")

    expect(downtown_box.visits.map { |v| v[:date].to_h }).to eq([{ value: "2026-01-05" }, { value: "2026-01-06" }])
  end

  it "refuses a tenant-scoped query with no tenant" do
    rented_box

    expect { runtime.query("Banking::SafeDepositBox.Rented") }
      .to raise_error(Hecks::Runtime::Unauthorized, /declares authorize with tenant: branch_code/)
  end

  it "scopes results away from another branch's box", :aggregate_failures do
    rented_box
    register_customer("c2", "B", "Customer", "b@example.com")
    rent("c2", "UPTOWN", 1, "small")

    expect(rented_ids("DOWNTOWN")).to eq(["DOWNTOWN:12"])
    expect(rented_ids("UPTOWN")).to eq(["UPTOWN:1"])
  end
end
