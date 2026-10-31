require "spec_helper"
require_relative "support/inline_bluebook_boot"

# A missing record names the command that creates it, when the aggregate declares one (ADR 0163
# step 10). An aggregate that declares no creator keeps the refusal it always had.
RSpec.describe "a missing record names its creator" do
  include InlineBluebookBoot

  CREATED_BY_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "CreatedByRefusal" do
      aggregate "Adr" do
        identified_by :number
        created_by "Adr.draft!"
        value_object "AdrNumber" do
          attribute :value, String
        end
        attribute :number, AdrNumber
        command "Accept" do
          reference_to Adr
          emits "AdrAccepted"
        end
      end

      aggregate "Note" do
        identified_by :number
        value_object "NoteNumber" do
          attribute :value, String
        end
        attribute :number, NoteNumber
        command "Revise" do
          reference_to Note
          emits "NoteRevised"
        end
      end
    end
  BLUEBOOK

  def booted_runtime
    boot(CREATED_BY_SOURCE, "CreatedByRefusal") do
      CreatedByRefusal::Adr.persisted_by("Memory")
      CreatedByRefusal::Note.persisted_by("Memory")
    end
  end

  def refusal_message(name)
    booted_runtime.dispatch_flat(name, id: "nope")
    nil
  rescue Hecks::Runtime::NotFound => e
    e.message
  end

  it "appends the creating command when the aggregate declares one" do
    expect(refusal_message("CreatedByRefusal::Adr.Accept")).to end_with("run Adr.draft! first")
  end

  it "keeps the plain refusal when the aggregate declares no creator" do
    expect(refusal_message("CreatedByRefusal::Note.Revise")).not_to include("run ")
  end
end
