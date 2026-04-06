require "spec_helper"

RSpec.describe Hecks::Workshop::BluebookMode do
  it "defines chapters as nested workshops" do
    workshop = Hecks.workshop("Shop")
    workshop.chapter("Pizzas") do
      aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } }
    end
    workshop.chapter("Billing") do
      aggregate("Invoice") { attribute :amount, Float; command("CreateInvoice") { attribute :amount, Float } }
    end

    expect(workshop.bluebook?).to be true
    expect(workshop.chapters).to eq(["Pizzas", "Billing"])
  end

  it "builds a BluebookStructure IR from chapters" do
    workshop = Hecks.workshop("Shop")
    workshop.chapter("Orders") do
      aggregate("Order") { attribute :qty, Integer; command("PlaceOrder") { attribute :qty, Integer } }
    end

    book = workshop.to_bluebook
    expect(book).to be_a(Hecks::DomainModel::Structure::BluebookStructure)
    expect(book.name).to eq("Shop")
    expect(book.chapters.size).to eq(1)
    expect(book.chapters.first.name).to eq("Orders")
  end

  it "plays all chapters with Hecks.open" do
    workshop = Hecks.workshop("PlayShop")
    workshop.chapter("Items") do
      aggregate("Item") { attribute :name, String; command("CreateItem") { attribute :name, String } }
    end
    workshop.chapter("Sales") do
      aggregate("Sale") { attribute :total, Float; command("RecordSale") { attribute :total, Float } }
    end

    workshop.play!
    expect(workshop.play?).to be true
  end
end
