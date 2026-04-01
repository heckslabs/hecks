require "spec_helper"

RSpec.describe "SQL migration expansion" do
  let(:strategy) { Hecks::Migrations::Strategies::SqlStrategy.new(output_dir: ".") }

  describe "NOT NULL from presence validation" do
    it "adds NOT NULL for presence-validated attributes on CREATE TABLE" do
      domain = Hecks.domain "NotNullTest" do
        aggregate "Pizza" do
          attribute :name, String
          attribute :style, String
          validation :name, presence: true

          command "CreatePizza" do
            attribute :name, String
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(nil, domain)
      sql = strategy.generate(changes)
      expect(sql).to include("name VARCHAR(255) NOT NULL")
      expect(sql).not_to include("style VARCHAR(255) NOT NULL")
    end

    it "adds NOT NULL for presence-validated attributes on ADD COLUMN" do
      old_domain = Hecks.domain "NotNullOld" do
        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
          end
        end
      end

      new_domain = Hecks.domain "NotNullNew" do
        aggregate "Pizza" do
          attribute :name, String
          attribute :email, String
          validation :email, presence: true
          command "CreatePizza" do
            attribute :name, String
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(old_domain, new_domain)
      sql = strategy.generate(changes)
      expect(sql).to include("email VARCHAR(255) NOT NULL")
    end
  end

  describe "UNIQUE from uniqueness validation" do
    it "adds UNIQUE constraint" do
      domain = Hecks.domain "UniqueTest" do
        aggregate "User" do
          attribute :email, String
          validation :email, uniqueness: true

          command "CreateUser" do
            attribute :email, String
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(nil, domain)
      sql = strategy.generate(changes)
      expect(sql).to include("email VARCHAR(255) UNIQUE")
    end
  end

  describe "DEFAULT values" do
    it "adds DEFAULT clause for attributes with defaults" do
      domain = Hecks.domain "DefaultTest" do
        aggregate "Pizza" do
          attribute :status, String, default: "draft"

          command "CreatePizza" do
            attribute :status, String
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(nil, domain)
      sql = strategy.generate(changes)
      expect(sql).to include("status VARCHAR(255) DEFAULT 'draft'")
    end

    it "handles numeric defaults" do
      domain = Hecks.domain "NumDefault" do
        aggregate "Item" do
          attribute :quantity, Integer, default: 0

          command "CreateItem" do
            attribute :quantity, Integer
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(nil, domain)
      sql = strategy.generate(changes)
      expect(sql).to include("quantity INTEGER DEFAULT 0")
    end
  end

  describe "foreign key cascading" do
    it "adds ON DELETE CASCADE to join table FKs" do
      domain = Hecks.domain "CascadeTest" do
        aggregate "Pizza" do
          attribute :name, String
          attribute :toppings, list_of("Topping")

          value_object "Topping" do
            attribute :name, String
          end

          command "CreatePizza" do
            attribute :name, String
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(nil, domain)
      sql = strategy.generate(changes)
      expect(sql).to include("ON DELETE CASCADE")
    end

    it "adds ON DELETE SET NULL to reference columns" do
      domain = Hecks.domain "RefTest" do
        aggregate "Order" do
          reference_to "Pizza"

          command "PlaceOrder" do
            reference_to "Pizza"
          end
        end
      end

      changes = Hecks::Migrations::DomainDiff.call(nil, domain)
      sql = strategy.generate(changes)
      expect(sql).to include("ON DELETE SET NULL")
    end
  end

end
