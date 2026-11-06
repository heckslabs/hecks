require_relative "workload"

module Hecks
  module Bench
    # The workloads the gate adds to pizzas and banking (ADR 0188 point 4, slice 2 of
    # docs/plans/kernel-thin-client.md), which the baseline left out: a verb that needs a fact,
    # and a reaction cascade. They are measured on `ruby:memory` and `rust:client` alike, and
    # each names the verb the gate judges, since the steps around it only prepare it.
    module GateWorkloads
      # A card per cascade cycle; with the close, the cascade is one command and ten events.
      CARDS = 9

      # A far-off expiry in epoch seconds, so an acquisition is never refused as already past.
      EXPIRY = 4_000_000_000

      # What the gate cannot measure yet, by the name the report gives it, and why.
      BLOCKED = {
        "port-policy" => "needs `ask: \"port\"` and a nested dispatch (a policy that calls a Ruby port " \
                         "operation); blocked by slice 6 of docs/plans/kernel-thin-client.md"
      }.freeze

      module_function

      # @return [Hash{String => Workload}] the extras, by report name
      def all
        { "needs-fact" => needs_fact, "cascade" => cascade }
      end

      # `Acquire` leaves out `now`, which it `needs`: the kernel asks the host for it each dispatch.
      def needs_fact
        Workload.new(name: "needs-fact", path: "qa/stress_domains/lease_clock", setup: [],
                     cycle: method(:needs_cycle), focus: "LeaseClock::Lease.Acquire")
      end

      def needs_cycle(number)
        key = { "value" => "lease-#{number}" }
        [Workload::Step.new("LeaseClock::Lease.Register", { "key" => key }),
         Workload::Step.new("LeaseClock::Lease.Acquire",
                            { "key" => key, "holder" => { "value" => "holder" }, "expiry" => { "value" => EXPIRY } })]
      end

      # `CloseAccount` retires every live card of the account by policy: one command, ten events.
      def cascade
        base = Workload.banking
        Workload.new(name: "cascade", path: "examples/banking", setup: base.setup,
                     cycle: method(:cascade_cycle), focus: "Banking::Account.CloseAccount")
      end

      def cascade_cycle(number)
        account = { "value" => "casc-#{number}" }
        [Workload.open_account(account), *Array.new(CARDS) { |card| issue_card(account, number, card) },
         Workload::Step.new("Banking::Account.CloseAccount", { "number" => account })]
      end

      def issue_card(account, number, card)
        Workload::Step.new("Banking::ATMCard.Issue",
                           { "account" => account.fetch("value"), "serial" => { "value" => "card-#{number}-#{card}" },
                             "daily_fee" => { "amount" => 0.0 } })
      end
    end
  end
end
