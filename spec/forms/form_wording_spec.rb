require "spec_helper"
require "hecks/forms"
require "rack/test"
require "tmpdir"
require "fileutils"

# A form is read by the person doing the work, so every label, heading and button is said in
# words drawn from the bluebook, and the code names stay in the inspect panel.
RSpec.describe "a generated form's wording" do
  include Rack::Test::Methods

  KITCHEN_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Kitchen" do
      vision "Put toppings on a pizza."

      aggregate "Order" do
        attribute :name, PizzaName
        attribute :toppings, list_of(Topping)
        identified_by :name

        value_object "PizzaName" do
          attribute :value, String, matches: :present
          invariant("a pizza is named") { !value.to_s.empty? }
        end

        value_object "ToppingName" do
          attribute :value, String, matches: :present
          invariant("a topping is named") { !value.to_s.empty? }
        end

        value_object "ToppingAmount" do
          attribute :value, Integer
          invariant("an amount is positive") { value.positive? }
        end

        value_object "Topping" do
          attribute :name, String
          attribute :amount, Integer
        end

        command "CreatePizza" do
          attribute :name, PizzaName
          sets :name
          emits PizzaCreated
        end

        command "AddTopping" do
          role "Chef"
          reference_to Order
          attribute :topping, ToppingName
          attribute :amount, ToppingAmount
          given("at most 10 toppings") { toppings.size < 10 }
          sets :toppings, append: { name: :topping, amount: :amount }
          emits ToppingAdded
        end
      end
    end
  RUBY

  around do |example|
    Dir.mktmpdir("kitchen") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      File.write(File.join(dir, "bluebook/kitchen.bluebook"), KITCHEN_BLUEBOOK)
      @runtime = Hecks.boot(dir, install_driving: false)
      example.run
    end
  end

  def app
    Hecks::Forms.configure("KitchenForms") { expose "Kitchen" }
    Hecks::Forms::App.for(registry: @runtime.registry, app_name: "KitchenForms")
  end

  def page(path)
    get path
    last_response.body
  end

  def label_for(body, path) = body[/<label for="f-#{path}">([^<]*)/, 1]

  def help_for(body, path) = body[/<span class="help" id="f-#{path}-help">([^<]*)/, 1]

  it "labels a single-field value object by the command's own name for it", :aggregate_failures do
    body = page("/Kitchen/Order/AddTopping.html")
    expect(label_for(body, "topping-value")).to eq("Topping")
    expect(label_for(body, "amount-value")).to eq("Amount")
  end

  it "says what each field accepts, from the declared pattern and invariants", :aggregate_failures do
    body = page("/Kitchen/Order/AddTopping.html")
    expect(help_for(body, "topping-value")).to eq("Must not be blank.")
    expect(help_for(body, "amount-value")).to eq("A whole number above zero.")
    expect(body).to include('aria-describedby="f-amount-value-help"')
  end

  it "names the record a command acts on in plain words", :aggregate_failures do
    body = page("/Kitchen/Order/AddTopping.html")
    expect(label_for(body, "to")).to eq("Order")
    expect(help_for(body, "to")).to eq("Which order this is for, by the order&#39;s name.")
  end

  it "titles the page and the button in words, keeping the code name in the inspect panel", :aggregate_failures do
    body = page("/Kitchen/Order/AddTopping.html")
    expect(body).to include("<h1>Add topping</h1>", '<button type="submit">Add topping</button>')
    expect(body).to include("<summary>Inspect: Kitchen::Order.AddTopping</summary>")
  end

  it "words the role and the preconditions plainly, with no dashes", :aggregate_failures do
    body = page("/Kitchen/Order/AddTopping.html")
    expect(body).to include("Done by: Chef (not checked in this preview)")
    expect(body).to include("<strong>Checked first.</strong> The action is refused if any of these fail:")
    expect(body).not_to include("—")
  end

  it "lists an aggregate's commands and queries by their names in words", :aggregate_failures do
    body = page("/Kitchen/Order.html")
    expect(body).to include("<h1>Orders</h1>", "+ Create pizza", "Commands and queries for orders")
    expect(body).to include("<span>Add topping</span>")
    expect(body).not_to include("Every command")
  end
end
