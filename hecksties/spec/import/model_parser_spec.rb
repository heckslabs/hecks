require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Import::ModelParser do
  let(:models_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(models_dir) }

  def write_model(name, content)
    File.write(File.join(models_dir, "#{name}.rb"), content)
  end

  subject(:parsed) { described_class.new(models_dir).parse }

  before do
    write_model("pizza", <<~RUBY)
      class Pizza < ApplicationRecord
        belongs_to :restaurant
        has_many :toppings
        has_many :orders, through: :order_items

        validates :name, presence: true
        validates :email, uniqueness: true

        enum status: { draft: 0, published: 1, archived: 2 }
      end
    RUBY

    write_model("order", <<~RUBY)
      class Order < ApplicationRecord
        belongs_to :customer

        include AASM
        aasm column: :state do
          state :pending, initial: true
          state :confirmed
          state :shipped

          event :confirm do
            transitions from: :pending, to: :confirmed
          end

          event :ship do
            transitions from: :confirmed, to: :shipped
          end
        end
      end
    RUBY
  end

  it "extracts class names" do
    expect(parsed.keys).to contain_exactly("Pizza", "Order")
  end

  it "extracts belongs_to" do
    assocs = parsed["Pizza"][:associations]
    expect(assocs).to include(hash_including(type: :belongs_to, name: "restaurant"))
  end

  it "extracts has_many" do
    assocs = parsed["Pizza"][:associations]
    expect(assocs).to include(hash_including(type: :has_many, name: "toppings"))
  end

  it "skips has_many through" do
    assocs = parsed["Pizza"][:associations]
    through = assocs.find { |a| a[:name] == "orders" }
    expect(through[:through]).to eq("order_items")
  end

  it "extracts validations" do
    validations = parsed["Pizza"][:validations]
    expect(validations).to include(hash_including(field: "name", rules: { presence: true }))
    expect(validations).to include(hash_including(field: "email", rules: { uniqueness: true }))
  end

  it "extracts enums (Rails 6 syntax)" do
    enums = parsed["Pizza"][:enums]
    expect(enums["status"]).to eq(%w[draft published archived])
  end

  it "extracts AASM state machine" do
    sm = parsed["Order"][:state_machine]
    expect(sm[:field]).to eq("state")
    expect(sm[:initial]).to eq("pending")
    expect(sm[:transitions]).to include(hash_including(event: "confirm", from: "pending", to: "confirmed"))
    expect(sm[:transitions]).to include(hash_including(event: "ship", from: "confirmed", to: "shipped"))
  end

  context "edge cases that broke the regex parser" do
    it "handles heredoc containing the word 'end'" do
      write_model("article", <<~RUBY)
        class Article < ApplicationRecord
          belongs_to :author
          validates :title, presence: true

          HELP_TEXT = <<~HEREDOC
            This is the end of the story.
            end of file marker
          HEREDOC

          enum status: { draft: 0, published: 1 }
        end
      RUBY

      expect(parsed["Article"][:associations]).to include(hash_including(type: :belongs_to, name: "author"))
      expect(parsed["Article"][:validations]).to include(hash_including(field: "title"))
      expect(parsed["Article"][:enums]["status"]).to eq(%w[draft published])
    end

    it "handles one-line method definitions without confusing the class extractor" do
      write_model("product", <<~RUBY)
        class Product < ApplicationRecord
          belongs_to :category
          validates :name, presence: true

          def greeting = "Hello"
          def label = name.upcase
        end
      RUBY

      expect(parsed["Product"][:associations]).to include(hash_including(type: :belongs_to, name: "category"))
      expect(parsed["Product"][:validations]).to include(hash_including(field: "name"))
    end

    it "scopes attr_accessor to the correct class and does not bleed into sibling classes" do
      write_model("user", <<~RUBY)
        class User < ApplicationRecord
          attr_accessor :password
          belongs_to :account
        end

        class Admin < ApplicationRecord
          belongs_to :organization
          validates :email, uniqueness: true
        end
      RUBY

      expect(parsed["User"][:associations]).to include(hash_including(type: :belongs_to, name: "account"))
      expect(parsed["Admin"][:associations]).to include(hash_including(type: :belongs_to, name: "organization"))
      expect(parsed["Admin"][:validations]).to include(hash_including(field: "email"))
      # The attr_accessor from User must not appear in Admin's associations
      expect(parsed["Admin"][:associations].map { |a| a[:name] }).not_to include("password")
    end
  end
end
