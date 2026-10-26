require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A command may name several roles, any one of which may run it: `role "Customer", "Sales Rep"`.
# `role` stays the first, the IR gains `roles` only when there is more than one, and a caller
# holding any of them is let through.
RSpec.describe "a command run by several roles" do
  DESK = <<~RUBY.freeze
    Hecks.bluebook "Desk" do
      aggregate "Ticket" do
        identified_by :number
        attribute :number, TicketNumber

        value_object "TicketNumber" do
          attribute :value, String
        end

        command "Open" do
          role "Customer", "Sales Rep"
          attribute :number, TicketNumber
          sets :number
          emits "TicketOpened"
        end

        command "Close" do
          role "Agent"
          attribute :number, TicketNumber
          sets :number
          emits "TicketClosed"
        end
      end
    end
  RUBY

  let(:scratch) { Dir.mktmpdir }
  let(:runtime) { boot(DESK) }

  after { FileUtils.remove_entry(scratch) }

  def boot(text)
    path = File.join(scratch, "desk.bluebook")
    File.write(path, text)
    Hecks.boot_files([path], install_driving: false)
  end

  def command_ir(name)
    ir = Hecks::Projector::Exporter.call(runtime.registry).fetch("Desk")
    ir.fetch(:aggregates).first.fetch(:commands).find { |command| command[:name] == name }
  end

  # Dispatches as a caller holding `role`; the domain boots first, as nobody in particular.
  def run_as(role, command, number)
    booted = runtime
    Hecks.as_caller(role: role) { booted.dispatch("Desk::Ticket.#{command}", with: { number: number }) }
  end

  it "keeps the first as `role` and lists every role under `roles`" do
    expect(command_ir("Open")).to include(role: "Customer", roles: ["Customer", "Sales Rep"])
  end

  it "leaves `roles` out of the IR of a command with one role" do
    expect(command_ir("Close")).to include(role: "Agent").and(satisfy { |ir| !ir.key?(:roles) })
  end

  it "lets a caller holding the first role run it" do
    expect { run_as("Customer", "Open", "T-1") }.not_to raise_error
  end

  it "lets a caller holding another of the roles run it" do
    expect { run_as("Sales Rep", "Open", "T-2") }.not_to raise_error
  end

  it "refuses a caller holding none, naming them all" do
    expect { run_as("Viewer", "Open", "T-9") }.to raise_error(
      Hecks::Runtime::Unauthorized, "Open refused — role: Customer or Sales Rep, and the caller stated Viewer"
    )
  end

  it "leaves a one-role command refusing as it always did" do
    expect { run_as("Customer", "Close", "T-1") }.to raise_error(
      Hecks::Runtime::Unauthorized, "Close refused — role: Agent, and the caller stated Customer"
    )
  end

  it "refuses naming a role twice" do
    text = DESK.sub('role "Customer", "Sales Rep"', 'role "Customer", "Customer"')

    expect { boot(text) }.to raise_error(StandardError, /role/)
  end

  it "refuses declaring roles twice" do
    text = DESK.sub('role "Customer", "Sales Rep"', %(role "Customer"\n      role "Sales Rep"))

    expect { boot(text) }.to raise_error(StandardError, /role/)
  end
end
