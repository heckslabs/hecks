require "spec_helper"

RSpec.describe Hecks::DSL::BluebookBuilder do
  it "builds a bluebook with chapters" do
    book = Hecks.bluebook("PizzaShop") do
      chapter "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          command("CreatePizza") { attribute :name, String }
        end
      end

      chapter "Billing" do
        aggregate "Invoice" do
          attribute :amount, Float
          command("CreateInvoice") { attribute :amount, Float }
        end
      end
    end

    expect(book).to be_a(Hecks::DomainModel::Structure::BluebookStructure)
    expect(book.name).to eq("PizzaShop")
    expect(book.chapters.size).to eq(2)
    expect(book.chapters.map(&:name)).to eq(["Pizzas", "Billing"])
  end

  it "chapters are valid Domain IR objects" do
    book = Hecks.bluebook("Shop") do
      chapter "Orders" do
        aggregate "Order" do
          attribute :quantity, Integer
          command("PlaceOrder") { attribute :quantity, Integer }
        end
      end
    end

    chapter = book.chapters.first
    expect(chapter).to be_a(Hecks::DomainModel::Structure::Domain)
    expect(chapter.aggregates.first.name).to eq("Order")
    expect(chapter.aggregates.first.commands.first.name).to eq("PlaceOrder")
  end

  it "rejects duplicate chapter names" do
    expect {
      Hecks.bluebook("Shop") do
        chapter("A") { aggregate("X") { attribute :n, String } }
        chapter("A") { aggregate("Y") { attribute :n, String } }
      end
    }.to raise_error(ArgumentError, /Duplicate chapter/)
  end

  it "stores last_bluebook on Hecks" do
    book = Hecks.bluebook("TestBook") do
      chapter "Ch1" do
        aggregate("Foo") { attribute :x, String }
      end
    end

    expect(Hecks.last_bluebook).to eq(book)
  end

  it "supports cross-chapter policy references" do
    book = Hecks.bluebook("CrossTest") do
      chapter "Pizzas" do
        aggregate "Order" do
          attribute :quantity, Integer
          command("PlaceOrder") { attribute :quantity, Integer }
        end
      end

      chapter "Billing" do
        aggregate "Invoice" do
          attribute :amount, Float
          command("CreateInvoice") { attribute :amount, Float }
        end

        policy "AutoInvoice" do
          on "PlacedOrder"
          trigger "CreateInvoice"
        end
      end
    end

    expect(book.all_policies.size).to eq(1)
    expect(book.all_policies.first.name).to eq("AutoInvoice")
    expect(book.chapter_for_command("CreateInvoice").name).to eq("Billing")
  end
end
