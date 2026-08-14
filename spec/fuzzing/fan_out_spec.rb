
require "spec_helper"
require "hecksagain/fuzzing"

# `Replay.fan_out_findings` cannot be exercised through `Replay.call`
# itself — that needs a domain PATH to boot fresh from disk
# (`IsolatedBoot`), and `for_each` has no on-disk fixture yet (the same
# "Rust parser does not build where/for_each" reason `spec/runtime/
# policy_spec.rb` builds its own Fanout domain INLINE — see that file's
# own header). So this spec builds the identical inline runtime and
# calls the oracle directly against real dispatches, proving the
# INDEPENDENT recomputation (`Ports::Query::InMemory` against the live
# repository) actually agrees with what `PolicyInterpreter#deliver_for_each`
# really dispatched — the same two-engines-compared shape
# `query_answers_match_reference` already trusts, aimed at fan-out.
RSpec.describe "Hecksagain::Fuzzing::Replay.fan_out_findings" do
  def boot_fanout
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Fanout" do
        aggregate "Customer" do
          identified_by { customer_id.value }
          attribute :customer_id, CustomerId
          attribute :risk,        RiskLevel

          value_object("CustomerId") { attribute :value, String }
          value_object("RiskLevel")  { attribute :value, String }

          command "Flag" do
            role "Ops"
            goal "flag a customer's risk level"
            attribute :customer_id, CustomerId
            attribute :risk,        RiskLevel
            then_set :customer_id, to: :customer_id
            then_set :risk,        to: :risk
            emits "Flagged"
          end
        end

        aggregate "Account" do
          identified_by { account_id.value }
          attribute :account_id,  AccountId
          attribute :customer_id, AccountCustomerId
          attribute :status,      AccountStatus

          value_object("AccountId")         { attribute :value, String }
          value_object("AccountCustomerId") { attribute :value, String }
          value_object("AccountStatus")     { attribute :value, String }

          command "Open" do
            role "Ops"
            goal "open an account"
            attribute :account_id,  AccountId
            attribute :customer_id, AccountCustomerId
            then_set :account_id,  to: :account_id
            then_set :customer_id, to: :customer_id
            then_set :status,      to: { value: "open" }
            emits "Opened"
          end

          command "Review" do
            role "Ops"
            goal "open a review on an account"
            reference_to Account
            attribute :customer_id, AccountCustomerId, optional: true
            attribute :risk,        String,            optional: true
            then_set :status, to: { value: "reviewing" }
            emits "Reviewed"
          end

          query "OpenForCustomer" do
            attribute :customer_id, AccountCustomerId
            where(customer_id: :customer_id, "status.value": "open")
          end
        end

        policy "ReviewOnFlag" do
          on       "Customer.Flagged"
          where { risk == "high" }
          for_each "Account.OpenForCustomer"
          trigger  "Account.Review"
        end
      end

      Hecks.hecksagon("Fanout") do
        ::Fanout::Customer.persisted_by("Memory")
        ::Fanout::Account.persisted_by("Memory")
      end
    end

    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  def open_two_accounts_for(runtime, customer_id)
    runtime.dispatch("Fanout::Account.Open", account_id: { value: "#{customer_id}-a1" },
                                             customer_id: { value: customer_id })
    runtime.dispatch("Fanout::Account.Open", account_id: { value: "#{customer_id}-a2" },
                                             customer_id: { value: customer_id })
  end

  # Mirrors `Replay.call`'s own snapshot-before-dispatch — the real
  # `deliver_for_each` runs its query synchronously, inside this SAME
  # dispatch, so the oracle has to read the SAME "before this step"
  # state the real query read, not whatever the fan-out's own dispatched
  # commands (`Account.Review`) already mutated by the time this method
  # gets to look.
  def flag(runtime, customer_id, risk)
    account = runtime.registry.bluebook("Fanout").aggregate("Account")
    snapshot = { ["Fanout", "Account"] =>
                   runtime.registry.repository("Fanout", account).all.to_h { |record| [record.id, record.state.dup] } }

    mark = runtime.reactions.size
    result = runtime.dispatch("Fanout::Customer.Flag", customer_id: { value: customer_id }, risk: { value: risk })
    Hecksagain::Fuzzing::Replay.fan_out_findings(runtime, snapshot, result.events, runtime.reactions[mark..])
  end

  it "recomputes the SAME row-id set the real dispatch actually fanned out over" do
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")
    runtime.dispatch("Fanout::Account.Open", account_id: { value: "c2-a1" }, customer_id: { value: "c2" })

    findings = flag(runtime, "c1", "high")

    expect(findings).to contain_exactly(
      hash_including(policy: "ReviewOnFlag", on: "Flagged",
                     expected_row_ids: ["c1-a1", "c1-a2"], actual_row_ids: ["c1-a1", "c1-a2"])
    )
  end

  it "expects nothing (nil, not empty) when the where clause does not hold, and nothing was dispatched" do
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")

    findings = flag(runtime, "c1", "low")

    expect(findings).to contain_exactly(
      hash_including(policy: "ReviewOnFlag", on: "Flagged", expected_row_ids: nil, actual_row_ids: [])
    )
  end

  it "excludes another customer's account from the expected set, matching the real query's own where" do
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")
    runtime.dispatch("Fanout::Account.Open", account_id: { value: "c2-a1" }, customer_id: { value: "c2" })

    findings = flag(runtime, "c1", "high")

    expect(findings.first[:expected_row_ids]).not_to include("c2-a1")
  end

  it "feeds Properties.fanout_dispatches_once_per_matching_row a real, passing finding" do
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")

    findings = flag(runtime, "c1", "high")
    history = { fan_outs: findings }

    expect(Hecksagain::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)).to eq(true)
  end
end
