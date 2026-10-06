require "spec_helper"
require "hecks/fuzzing"

# Calls `Replay.fan_out_findings` directly: `Replay.call` needs an on-disk domain and
# `for_each` has no fixture (the Rust parser does not build it; see spec/runtime/policy_spec.rb).
RSpec.describe "Hecks::Fuzzing::Replay.fan_out_findings" do
  # One inline bluebook read top to bottom as the fixture; splitting it would scatter it.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def boot_fanout
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Fanout" do
        aggregate "Customer" do
          identified_by :customer_id
          attribute :customer_id, CustomerId
          attribute :risk,        RiskLevel

          value_object("CustomerId") { attribute :value, String }
          value_object("RiskLevel")  { attribute :value, String }

          command "Flag" do
            role "Ops"
            goal "flag a customer's risk level"
            attribute :customer_id, CustomerId
            attribute :risk,        RiskLevel
            sets :customer_id
            sets :risk
            emits "Flagged"
          end
        end

        aggregate "Account" do
          identified_by :account_id
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
            sets :account_id
            sets :customer_id
            sets :status, to: { value: "open" }
            emits "Opened"
          end

          command "Review" do
            role "Ops"
            goal "open a review on an account"
            reference_to Account
            attribute :customer_id, AccountCustomerId, optional: true
            attribute :risk,        String,            optional: true
            sets :status, to: { value: "reviewing" }
            emits "Reviewed"
          end

          query "OpenForCustomer" do
            attribute :customer_id, AccountCustomerId
            where(customer_id: :customer_id, "status.value": "open")
          end
        end

        policy "ReviewOnFlag" do
          on "Customer.Flagged"
          where { risk == "high" }
          for_each "Account.OpenForCustomer"
          trigger  Account::Review
        end
      end

      Hecks.hecksagon("Fanout") do
        attaches "Governance"
        Fanout::Customer.persisted_by("Memory")
        Fanout::Account.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def open_two_accounts_for(runtime, customer_id)
    runtime.dispatch_flat("Fanout::Account.Open", account_id:  { value: "#{customer_id}-a1" },
                                                  customer_id: { value: customer_id })
    runtime.dispatch_flat("Fanout::Account.Open", account_id:  { value: "#{customer_id}-a2" },
                                                  customer_id: { value: customer_id })
  end

  # Snapshot before dispatch, as `Replay.call` does: the oracle must read the state the
  # real query saw, not what the fan-out's own `Account.Review` dispatches already mutated.
  def account_snapshot(runtime)
    account = runtime.registry.bluebook("Fanout").aggregate("Account")
    records = runtime.registry.repository("Fanout", account).all
    { ["Fanout", "Account"] => records.to_h { |record| [record.id, record.state.dup] } }
  end

  def flag(runtime, customer_id, risk)
    snapshot = account_snapshot(runtime)
    mark = runtime.reactions.size
    result = runtime.dispatch_flat("Fanout::Customer.Flag", customer_id: { value: customer_id }, risk: { value: risk })
    Hecks::Fuzzing::Replay.fan_out_findings(runtime, snapshot, result.events, runtime.reactions[mark..])
  end

  # A booted runtime holding two accounts of customer c1 and one of customer c2.
  def booted_with_two_customers
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")
    runtime.dispatch_flat("Fanout::Account.Open", account_id: { value: "c2-a1" }, customer_id: { value: "c2" })
    runtime
  end

  def review_finding(**row_ids) = hash_including(policy: "ReviewOnFlag", on: "Flagged", **row_ids)

  it "recomputes the SAME row-id set the real dispatch actually fanned out over" do
    findings = flag(booted_with_two_customers, "c1", "high")

    expect(findings).to contain_exactly(review_finding(expected_row_ids: ["c1-a1", "c1-a2"], actual_row_ids: ["c1-a1", "c1-a2"]))
  end

  it "expects nothing (nil, not empty) when the where clause does not hold, and nothing was dispatched" do
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")

    findings = flag(runtime, "c1", "low")

    expect(findings).to contain_exactly(review_finding(expected_row_ids: nil, actual_row_ids: []))
  end

  it "excludes another customer's account from the expected set, matching the real query's own where" do
    findings = flag(booted_with_two_customers, "c1", "high")

    expect(findings.first[:expected_row_ids]).not_to include("c2-a1")
  end

  it "feeds Properties.fanout_dispatches_once_per_matching_row a real, passing finding" do
    runtime = boot_fanout
    open_two_accounts_for(runtime, "c1")

    findings = flag(runtime, "c1", "high")
    history = { fan_outs: findings }

    expect(Hecks::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)).to be(true)
  end
end
