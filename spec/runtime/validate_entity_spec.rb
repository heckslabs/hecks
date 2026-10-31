require "spec_helper"
require_relative "../support/booted_source"

# `Dispatcher#validate` on an entity command: the parent record and the element are found in
# one stage, so a parent that is missing must end the stage with its one refusal, the way
# `dry_run?` raises it, and never reach the element step with no record to read.
RSpec.describe Hecks::Runtime::Dispatcher, "#validate of an entity command" do
  SHELVED_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Shelved" do
      aggregate "Shelf" do
        identified_by :tag
        attribute :tag,   Tag
        attribute :books, list_of(Book)
        value_object("Tag")    { attribute :value, String }
        value_object("BookId") { attribute :value, String }
        command("Build") do
          attribute :tag, Tag
          emits "ShelfBuilt"
        end
        command("Stock") do
          reference_to Shelf
          attribute :id, BookId
          sets :books, append: { id: :id }
          emits "BookStocked"
        end
        entity "Book" do
          attribute :id, BookId
          identified_by :id
          lifecycle :status, default: "shelved" do
            transition "Pull" => "pulled", from: "shelved"
          end
          command("Pull") do
            emits "BookPulled"
          end
        end
      end
    end
  BLUEBOOK

  let(:dispatcher) do
    BootedSource.boot(SHELVED_SOURCE) { Hecks.hecksagon("Shelved") { Shelved::Shelf.persisted_by("Memory") } }
  end

  def stock(tag, id)
    dispatcher.dispatch_flat("Shelved::Shelf.Build", tag: { value: tag })
    dispatcher.dispatch_flat("Shelved::Shelf.Stock", tag: tag, id: { value: id })
  end

  def validating_pull(tag:, id:) = dispatcher.validate_facts("Shelved::Shelf.Book.Pull", tag: tag, id: { value: id })

  def raised_pull(tag:, id:)
    dispatcher.dry_run?("Shelved::Shelf.Book.Pull", tag: tag, id: { value: id })
    nil
  rescue Hecks::Refused => e
    e
  end

  it "refuses a parent that does not exist with the one reason dry_run? raises", :aggregate_failures do
    result = validating_pull(tag: "none", id: "b1")

    expect(result.refusals.map { |r| [r.class, r.stage] }).to eq([[Hecks::Runtime::NotFound, :state]])
    expect(result.refusals.first.message).to eq(raised_pull(tag: "none", id: "b1").message)
  end

  it "refuses an element its parent does not hold with the one reason dry_run? raises", :aggregate_failures do
    stock("s1", "b1")

    result = validating_pull(tag: "s1", id: "b9")

    expect(result.refusals.map { |r| [r.class, r.stage] }).to eq([[Hecks::Runtime::NotFound, :state]])
    expect(result.refusals.first.message).to eq(raised_pull(tag: "s1", id: "b9").message)
  end

  it "accepts the command when the parent holds the element" do
    stock("s1", "b1")

    expect(validating_pull(tag: "s1", id: "b1")).to be_ok
  end
end
