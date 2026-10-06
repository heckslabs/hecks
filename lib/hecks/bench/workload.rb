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
        new(name: "pizzas", setup: [], cycle: lambda { |n|
          pizza = "pizza-#{n}"
          [
            Step.new("Pizzas::Order.CreatePizza",
                     { "name"  => { "value" => pizza },
                       "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } } }),
            Step.new("Pizzas::Order.AddTopping",
                     { "name" => pizza, "topping" => { "value" => "Basil" }, "amount" => { "value" => 3 } }),
            Step.new("Pizzas::Order.AddTopping",
                     { "name" => pizza, "topping" => { "value" => "Olive" }, "amount" => { "value" => 2 } }),
            Step.new("Pizzas::Order.Purchase",
                     { "name" => pizza, "customer_name" => { "value" => "Chris" },
                       "amount" => { "cents" => 1200 } })
          ]
        })
      end

      def self.banking
        register = Step.new("Banking::Customer.Register",
                            { "reference" => { "value" => "CUST-0001" },
                              "name"      => { "given" => "Ada", "family" => "Lovelace" },
                              "email"     => { "address" => "ada@example.com" } })
        new(name: "banking", setup: [register], cycle: lambda { |n|
          number = { "value" => "acct-#{n}" }
          money = ->(cents) { { "cents" => cents, "currency" => "USD" } }
          [
            Step.new("Banking::Account.Open",
                     { "number" => number, "kind" => { "name" => "current" },
                       "daily_limit" => { "cents" => 50_000 }, "customer" => "CUST-0001" }),
            Step.new("Banking::Account.Credit",
                     { "number" => number, "amount" => money.call(10_000), "narrative" => { "text" => "Deposit" } }),
            Step.new("Banking::Account.Credit",
                     { "number" => number, "amount" => money.call(5000), "narrative" => { "text" => "Deposit" } }),
            Step.new("Banking::Account.Debit",
                     { "number" => number, "amount" => money.call(2500), "narrative" => { "text" => "Groceries" } })
          ]
        })
      end
    end
  end
end
