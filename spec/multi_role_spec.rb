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

  def with_desk
    Dir.mktmpdir do |dir|
      path = File.join(dir, "desk.bluebook")
      File.write(path, DESK)
      yield Hecks.boot_files([path], install_driving: false)
    end
  end

  def command_ir(runtime, name)
    ir = Hecks::Projector::Exporter.call(runtime.registry).fetch("Desk")
    ir.fetch(:aggregates).first.fetch(:commands).find { |command| command[:name] == name }
  end

  it "keeps the first as `role` and lists every role under `roles`, only when there are several" do
    with_desk do |runtime|
      expect(command_ir(runtime, "Open")).to include(role: "Customer", roles: ["Customer", "Sales Rep"])
      expect(command_ir(runtime, "Close")).to include(role: "Agent")
      expect(command_ir(runtime, "Close")).not_to have_key(:roles)
    end
  end

  it "lets a caller holding any of the roles run it" do
    with_desk do |runtime|
      ["Customer", "Sales Rep"].each_with_index do |role, index|
        Hecks.as_caller(role: role) do
          expect { runtime.dispatch("Desk::Ticket.Open", with: { number: "T-#{index}" }) }.not_to raise_error
        end
      end
    end
  end

  it "refuses a caller holding none, naming them all" do
    with_desk do |runtime|
      Hecks.as_caller(role: "Viewer") do
        expect { runtime.dispatch("Desk::Ticket.Open", with: { number: "T-9" }) }
          .to raise_error(Hecks::Runtime::Unauthorized,
                          "Open refused — role: Customer or Sales Rep, and the caller stated Viewer")
      end
    end
  end

  it "leaves a one-role command refusing as it always did" do
    with_desk do |runtime|
      Hecks.as_caller(role: "Customer") do
        expect { runtime.dispatch("Desk::Ticket.Close", with: { number: "T-1" }) }
          .to raise_error(Hecks::Runtime::Unauthorized, "Close refused — role: Agent, and the caller stated Customer")
      end
    end
  end

  it "refuses naming a role twice, and declaring roles twice" do
    twice = DESK.sub('role "Customer", "Sales Rep"', 'role "Customer", "Customer"')
    declared_twice = DESK.sub('role "Customer", "Sales Rep"', %(role "Customer"\n      role "Sales Rep"))

    [twice, declared_twice].each do |text|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "desk.bluebook")
        File.write(path, text)
        expect { Hecks.boot_files([path], install_driving: false) }.to raise_error(StandardError, /role/)
      end
    end
  end
end
