# Shared domain boot — build once, reuse everywhere.
# Include in spec_helper to make BootedDomains available to all specs.
#
require "tmpdir"

module BootedDomains
  @cache = {}

  def self.pizzas
    @pizzas_domain ||= Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :style, String
        attribute :description, String
        attribute :price, Float
        attribute :toppings, list_of("Topping")

        value_object "Topping" do
          attribute :name, String
          attribute :amount, Integer

          invariant "amount must be positive" do
            amount > 0
          end
        end

        validation :name, presence: true

        command "CreatePizza" do
          attribute :name, String
          attribute :style, String
          attribute :description, String
          attribute :price, Float
        end

        command "AddTopping" do
          reference_to "Pizza"
          attribute :topping, String
        end

        query "ByDescription" do |desc|
          where(description: desc)
        end

        query "Classics" do
          where(style: "Classic")
        end

        query "ByStyle" do |style|
          where(style: style)
        end

        scope :classics_scope, style: "Classic"
        scope :by_style_scope, ->(s) { { style: s } }
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer
        attribute :status, String

        validation :quantity, presence: true

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        command "CancelOrder" do
          reference_to "Order"
        end

        command "ReserveStock" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        query "Pending" do
          where(status: "pending")
        end

        policy "ReserveIngredients" do
          on "PlacedOrder"
          trigger "ReserveStock"
        end
      end
    end
  end

  def self.boot(domain)
    key = domain.object_id
    return @cache[key] if @cache[key]

    runtime = Hecks.load(domain)
    runtime.capability(:crud)
    @cache[key] = runtime
  end
end
