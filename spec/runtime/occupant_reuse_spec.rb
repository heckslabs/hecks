require "spec_helper"

# A creating command that meets an occupied id: a live occupant refuses, an ended one is archived.
RSpec.describe "creating over an occupied id" do
  REUSE_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/occupant_reuse/occupant_reuse.bluebook")

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(REUSE_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def repository(name)
    runtime.registry.repository("OccupantReuse", runtime.registry.bluebook("OccupantReuse").aggregate(name))
  end

  def open_ticket(title = "first")
    runtime.dispatch_flat("OccupantReuse::Ticket.Open", code: { value: "T1" }, title: { value: title })
  end

  def close_ticket = runtime.dispatch_flat("OccupantReuse::Ticket.Close", code: { value: "T1" })

  def close_and_reopen(title = "again")
    close_ticket
    open_ticket(title)
  end

  def ticket_ids = repository("Ticket").all.map { |row| row.id.to_s }.sort

  it "refuses a live occupant" do
    open_ticket

    expect { open_ticket }.to raise_error(Hecks::Runtime::AlreadyExists)
  end

  it "archives a closed occupant as <id>~1 with its fields, then creates", :aggregate_failures do
    open_ticket
    close_and_reopen("second")

    expect(ticket_ids).to eq(["T1", "T1~1"])
    expect(repository("Ticket").find("T1~1")[:title].to_h).to eq(value: "first")
    expect(repository("Ticket").find("T1")[:status]).to eq("open")
  end

  it "counts earlier archives", :aggregate_failures do
    open_ticket
    close_and_reopen
    close_and_reopen

    expect(ticket_ids).to eq(["T1", "T1~1", "T1~2"])
  end

  it "archives an occupant whose status is no declared state" do
    open_ticket
    repository("Ticket").find("T1")[:status] = "gone"
    open_ticket("again")

    expect(ticket_ids).to eq(["T1", "T1~1"])
  end

  it "refuses an occupant of an aggregate with no lifecycle" do
    runtime.dispatch_flat("OccupantReuse::Note.Write", slug: { value: "n" })

    expect { runtime.dispatch_flat("OccupantReuse::Note.Write", slug: { value: "n" }) }
      .to raise_error(Hecks::Runtime::AlreadyExists)
  end

  it "writes no archive on a dry run over a closed occupant", :aggregate_failures do
    open_ticket
    close_ticket

    expect(runtime.dry_run?("OccupantReuse::Ticket.Open", code: { value: "T1" }, title: { value: "x" })).to be(true)
    expect(ticket_ids).to eq(["T1"])
  end
end
