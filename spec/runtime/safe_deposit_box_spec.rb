require "spec_helper"

RSpec.describe "a composite-identified aggregate with two entities" do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def rented_box(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::SafeDepositBox.Rent", customer: { value: "c" }, branch_code: { value: "DOWNTOWN" },
                                                     box_number: { value: 12 }, size: { value: "medium" })
  end

  it "accepts a customer identity fact and stores the declared relationship" do
    runtime = boot_banking
    box = runtime.registry.bluebook("Banking").aggregate("SafeDepositBox")
    rent = box.command("Rent")

    expect(box.attribute(:customer).relationship).to eq("belongs_to")
    expect([rent.attribute(:customer).type.to_s, rent.attribute(:customer).reference?])
      .to eq(["CustomerNumber", false])

    rented_box(runtime)
    expect(Banking::SafeDepositBox.find("DOWNTOWN:12")[:customer]).to eq("c")
  end

  it "is born at the join of its two identity paths" do
    runtime = boot_banking
    rented_box(runtime)

    box = Banking::SafeDepositBox.find("DOWNTOWN:12")
    expect(box.branch_code.to_h).to eq(value: "DOWNTOWN")
    expect(box.box_number.to_h).to  eq(value: 12)
    expect(box.status).to eq("rented")
  end

  it "logs a composite-identified entity, appended by its own two-path identity" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          date: { value: "2026-01-05" }, sequence: { value: 1 })
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          date: { value: "2026-01-05" }, sequence: { value: 2 })

    visits = Banking::SafeDepositBox.find("DOWNTOWN:12").visits
    expect(visits.map { |v| v[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
    expect(visits.map { |v| v[:state] }).to eq(%w[logged logged])
  end

  it "addresses the composite entity through the parent's composite identity" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          date: { value: "2026-01-05" }, sequence: { value: 1 })
    runtime.dispatch("Banking::SafeDepositBox.Visit.Annotate", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                                date: { value: "2026-01-05" }, sequence: { value: 1 },
                                                                note: { text: "Flagged" })

    visit = Banking::SafeDepositBox.find("DOWNTOWN:12").visits.first
    expect(visit[:note].to_h).to eq(text: "Flagged")
  end

  it "carries a single-identified entity beside a composite one on the same head" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.IssueKey", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          serial: { value: "KEY-1" })

    key = Banking::SafeDepositBox.find("DOWNTOWN:12").keys.first
    expect(key[:serial].to_h).to eq(value: "KEY-1")
    expect(key[:status]).to eq("issued")

    runtime.dispatch("Banking::SafeDepositBox.KeyIssuance.Return", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                                    serial: { value: "KEY-1" })
    expect(Banking::SafeDepositBox.find("DOWNTOWN:12").keys.first[:status]).to eq("returned")
  end

  it "refuses to log a visit against a box that is not rented" do
    runtime = boot_banking
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::SafeDepositBox.Rent", customer: "c", branch_code: { value: "DOWNTOWN" },
                                                     box_number: { value: 12 }, size: { value: "medium" })
    runtime.dispatch("Banking::SafeDepositBox.Surrender", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 })

    expect do
      runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                            date: { value: "2026-01-05" }, sequence: { value: 1 })
    end.to raise_error(Hecks::Runtime::GivenNotMet, /only a rented box is opened/)
  end

  it "refuses to return a key that is not issued" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.IssueKey", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          serial: { value: "KEY-1" })
    runtime.dispatch("Banking::SafeDepositBox.KeyIssuance.Return", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                                    serial: { value: "KEY-1" })

    expect do
      runtime.dispatch("Banking::SafeDepositBox.KeyIssuance.Return", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                                      serial: { value: "KEY-1" })
    end.to raise_error(Hecks::Runtime::GivenNotMet, /only an issued key is returned/)
  end

  it "announces two facts from one dispatch, and refuses a second surrender" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.Surrender", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 })

    names = runtime.events.map(&:name)
    expect(names).to include("BoxSurrendered", "KeyReturnDue")
    expect(Banking::SafeDepositBox.find("DOWNTOWN:12").status).to eq("vacant")

    expect do
      runtime.dispatch("Banking::SafeDepositBox.Surrender", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 })
    end.to raise_error(Hecks::Runtime::GivenNotMet, /only a rented box is surrendered/)
  end

  it "answers a query with the closed-set attribute the inline shorthand declared" do
    runtime = boot_banking
    rented_box(runtime)

    rows = runtime.query("Banking::SafeDepositBox.Rented", branch_code: "DOWNTOWN")
    expect(rows.map { |row| row[:id] }).to eq(["DOWNTOWN:12"])
    expect(rows.first[:size].to_h).to eq(value: "medium")
  end

  it "refuses a second LogVisit that collides on the composite date+sequence identity" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          date: { value: "2026-01-05" }, sequence: { value: 1 })

    expect do
      runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                            date: { value: "2026-01-05" }, sequence: { value: 1 })
    end.to raise_error(Hecks::Runtime::AlreadyExists, /Visit.*already exists/)

    # THE ONE THAT DID LAND STANDS — a refused second write leaves the
    # first exactly as it was, not doubled and not gone.
    visits = Banking::SafeDepositBox.find("DOWNTOWN:12").visits
    expect(visits.size).to eq(1)
  end

  it "refuses a second IssueKey that collides on the single serial identity" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.IssueKey", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          serial: { value: "KEY-1" })

    expect do
      runtime.dispatch("Banking::SafeDepositBox.IssueKey", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                            serial: { value: "KEY-1" })
    end.to raise_error(Hecks::Runtime::AlreadyExists, /KeyIssuance.*already exists/)

    keys = Banking::SafeDepositBox.find("DOWNTOWN:12").keys
    expect(keys.size).to eq(1)
  end

  it "does not spuriously flag an auto-minted entity list — two visits on different days both land" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          date: { value: "2026-01-05" }, sequence: { value: 1 })
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                                          date: { value: "2026-01-06" }, sequence: { value: 1 })

    visits = Banking::SafeDepositBox.find("DOWNTOWN:12").visits
    expect(visits.map { |v| v[:date].to_h }).to eq([{ value: "2026-01-05" }, { value: "2026-01-06" }])
  end

  it "refuses a tenant-scoped query with no tenant, and scopes results away from another branch's box" do
    runtime = boot_banking
    rented_box(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c2" },
                     name: { given: "B", family: "Customer" }, email: { address: "b@example.com" })
    runtime.dispatch("Banking::SafeDepositBox.Rent", customer: "c2", branch_code: { value: "UPTOWN" },
                                                     box_number: { value: 1 }, size: { value: "small" })

    expect { runtime.query("Banking::SafeDepositBox.Rented") }
      .to raise_error(Hecks::Runtime::Unauthorized, /declares authorize with tenant: branch_code/)

    downtown = runtime.query("Banking::SafeDepositBox.Rented", branch_code: "DOWNTOWN")
    expect(downtown.map { |row| row[:id] }).to eq(["DOWNTOWN:12"])

    uptown = runtime.query("Banking::SafeDepositBox.Rented", branch_code: "UPTOWN")
    expect(uptown.map { |row| row[:id] }).to eq(["UPTOWN:1"])
  end
end
