require "json"

module Hecks
  module Bench
    # A fixed command sequence for one example domain, identical for every runtime.
    # Cycles name their records by `n`, so no command is refused and none times a rejection path.
    class Workload
      Step = Struct.new(:verb, :args) do
        def to_json_line
          JSON.generate("verb" => verb, "args" => args)
        end

        def ruby_args
          args.transform_keys(&:to_sym)
        end
      end

      # The example domain's directory name, also its Cargo feature.
      attr_reader :name

      # The absolute path of the example domain directory.
      attr_reader :domain_path

      # The commands run once, untimed, before any cycle.
      attr_reader :setup

      def initialize(name:, setup:, cycle:)
        @name = name
        @domain_path = File.expand_path("../../../examples/#{name}", __dir__)
        @setup = setup
        @cycle = cycle
      end

      def cycle(number) = @cycle.call(number)

      def commands_per_cycle = cycle(0).size

      def self.all
        { "pizzas" => pizzas, "banking" => banking }
      end

      def self.fetch(name)
        all.fetch(name) do
          raise ArgumentError, "unknown domain #{name.inspect} — one of #{all.keys.join(", ")}"
        end
      end

      def self.pizzas
        new(name: "pizzas", setup: [], cycle: method(:pizza_cycle))
      end

      def self.pizza_cycle(number)
        pizza = "pizza-#{number}"
        [create_pizza(pizza), add_topping(pizza, "Basil", 3), add_topping(pizza, "Olive", 2), purchase(pizza)]
      end

      def self.create_pizza(pizza)
        Step.new("Pizzas::Order.CreatePizza",
                 { "name"  => { "value" => pizza },
                   "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } } })
      end

      def self.add_topping(pizza, topping, amount)
        Step.new("Pizzas::Order.AddTopping",
                 { "name" => pizza, "topping" => { "value" => topping }, "amount" => { "value" => amount } })
      end

      def self.purchase(pizza)
        Step.new("Pizzas::Order.Purchase",
                 { "name" => pizza, "customer_name" => { "value" => "Chris" }, "amount" => { "cents" => 1200 } })
      end

      def self.banking
        register = Step.new("Banking::Customer.Register",
                            { "reference" => { "value" => "CUST-0001" },
                              "name"      => { "given" => "Ada", "family" => "Lovelace" },
                              "email"     => { "address" => "ada@example.com" } })
        new(name: "banking", setup: [register], cycle: method(:banking_cycle))
      end

      def self.banking_cycle(number)
        account = { "value" => "acct-#{number}" }
        [open_account(account), ledger_step("Credit", account, 10_000, "Deposit"),
         ledger_step("Credit", account, 5000, "Deposit"), ledger_step("Debit", account, 2500, "Groceries")]
      end

      def self.open_account(account)
        Step.new("Banking::Account.Open",
                 { "number" => account, "kind" => { "name" => "current" },
                   "daily_limit" => { "cents" => 50_000 }, "customer" => "CUST-0001" })
      end

      def self.ledger_step(verb, account, cents, narrative)
        Step.new("Banking::Account.#{verb}",
                 { "number" => account, "amount" => { "cents" => cents, "currency" => "USD" },
                   "narrative" => { "text" => narrative } })
      end
    end
  end
end
