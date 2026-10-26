require "spec_helper"
require_relative "../support/booted_source"

# Whether a record's state lets a command run is answerable before any argument is known, which
# `validate` cannot say: it stops at the arguments stage when one is missing.
RSpec.describe Hecks::Runtime::Dispatcher, "#state_admits?" do
  PANTRY_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Pantry" do
      aggregate "Jar" do
        identified_by :label
        attribute :label, Label
        value_object("Label") { attribute :value, String }
        value_object("Note") { attribute :value, String }
        lifecycle :status, default: "sealed" do
          transition "Open" => "opened", from: "sealed"
        end
        command("Fill") do
          attribute :label, Label
          sets :label
          emits "JarFilled"
        end
        command("Open", from: "sealed") do
          reference_to Jar
          attribute :note, Note
          emits "JarOpened"
        end
      end
    end
  BLUEBOOK

  let(:dispatcher) do
    BootedSource.boot(PANTRY_SOURCE) { Hecks.hecksagon("Pantry") { Pantry::Jar.persisted_by("Memory") } }
  end

  let(:jar) { dispatcher.registry.bluebook("Pantry").aggregates.first }
  let(:open_command) { jar.commands.find { |command| command.hecks_name == "Open" } }

  def fill(label) = dispatcher.dispatch_flat("Pantry::Jar.Fill", label: { value: label })

  def admits?(label) = dispatcher.state_admits?("Pantry", jar, open_command, label)

  it "admits a command from the state it is declared for" do
    fill("j1")

    expect(admits?("j1")).to be(true)
  end

  it "refuses a command once the record has moved on" do
    fill("j2")
    dispatcher.dispatch_flat("Pantry::Jar.Open", to: "j2", note: { value: "first" })

    expect(admits?("j2")).to be(false)
  end
end
