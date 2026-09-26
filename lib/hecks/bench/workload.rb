require "json"

module Hecks
  module Bench
    # A fixed command sequence for one example domain, identical for every runtime.
    #
    # `setup` runs once, untimed, before a run starts. `cycle(n)` answers the timed
    # commands for the n-th unit of work. Every cycle names its own records by `n`, so
    # cycles never collide and no command is ever refused: a refusal would mean the
    # benchmark measured a rejection path rather than the work it claims.
    #
    # Steps are the same `{"verb", "args"}` shape `bin/run` and the corpus scripts use.
    # Ruby dispatches them through `dispatch_flat` and the Rust binary reads them as
    # JSON lines, so both runtimes see byte-identical input.
    class Workload
      # One command to dispatch.
      #
      # @!attribute verb
      #   @return [String] the fully qualified command, e.g. `"Pizzas::Order.CreatePizza"`
      # @!attribute args
      #   @return [Hash{String => Object}] the command's arguments, string-keyed throughout
      Step = Struct.new(:verb, :args) do
        # Renders the step as one line of `rust --serve` input.
        #
        # @return [String] the step as compact JSON with no trailing newline
        def to_json_line
          JSON.generate("verb" => verb, "args" => args)
        end

        # Gives the arguments as `dispatch_flat` takes them.
        #
        # @return [Hash{Symbol => Object}] `args` with only its top-level keys symbolized,
        #   the way the corpus replay hands them over
        def ruby_args
          args.transform_keys(&:to_sym)
        end
      end

      # @return [String] the example domain's directory name, also its Cargo feature
      attr_reader :name

      # @return [String] the absolute path of the example domain directory
      attr_reader :domain_path

      # @return [Array<Step>] the commands run once, untimed, before any cycle
      attr_reader :setup

      # Builds a workload.
      #
      # @param name [String] the example domain's directory name, e.g. `"pizzas"`
      # @param setup [Array<Step>] the untimed preparation commands
      # @param cycle [#call] takes a cycle number and returns that cycle's `Array<Step>`
      def initialize(name:, setup:, cycle:)
        @name = name
        @domain_path = File.expand_path("../../../examples/#{name}", __dir__)
        @setup = setup
        @cycle = cycle
      end

      # Gives the timed commands for one unit of work.
      #
      # @param number [Integer] the zero-based cycle number, unique across warmup and
      #   measurement so record names never repeat
      # @return [Array<Step>] the commands in dispatch order
      def cycle(number) = @cycle.call(number)

      # Gives how many commands each cycle dispatches.
      #
      # @return [Integer] the length of every cycle
      def commands_per_cycle = cycle(0).size

      # Lists the workloads `bin/bench` knows.
      #
      # @return [Hash{String => Workload}] each workload keyed by its domain name
      def self.all
        { "pizzas" => pizzas, "banking" => banking }
      end

      # Looks up one workload.
      #
      # @param name [String] a key of `.all`
      # @return [Workload] the workload for `name`
      # @raise [ArgumentError] if there is no workload with that name
      def self.fetch(name)
        all.fetch(name) do
          raise ArgumentError, "unknown domain #{name.inspect} — one of #{all.keys.join(', ')}"
        end
      end

      # A pizza is created, topped twice and bought: four commands and two aggregate updates.
      #
      # @return [Workload] the pizzas workload
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

      # An account is opened, credited twice and debited once, all for one registered customer.
      #
      # @return [Workload] the banking workload
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
