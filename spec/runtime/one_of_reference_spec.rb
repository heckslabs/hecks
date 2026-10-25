require "spec_helper"
require_relative "../support/read_model_spec_helpers"

# ADR 0122: `reference_to one_of(A, B), as: :subject` is a tagged reference, stored as
# `{ type:, id: }`, to one of a closed union of aggregates.
RSpec.describe "a reference to one of a closed union" do
  include ReadModelSpecHelpers

  MALFORMED_UNION = Hecks::Bluebook::DSL::Malformed

  def runtime_with_subjects
    runtime = boot_banking_bundle(names: ReadModelSpecHelpers::BANKING_AGGREGATES + ["Hold"])
    Banking::Customer.register!(reference: "c-hold", name: { given: "A", family: "B" }, email: "hold@example.com")
    Banking::Account.open!(customer: "c-hold", number: "acct-hold", kind: "current", daily_limit: 10_000)
    Banking::ATMCard.issue!(account: "acct-hold", serial: "card-hold", daily_fee: { amount: 0.0 })
    runtime
  end

  def place(reference, type, id)
    Banking::Hold.place!(reference: reference, subject: { type: type, id: id }, reason: "review")
  end

  def holds_on_cards(runtime) = runtime.query("Banking.HoldsOnCards").first[:holds]

  it "holds the subject as a type and an id" do
    runtime = runtime_with_subjects
    place("h-1", "ATMCard", "card-hold")
    expect(holds_on_cards(runtime).first[:subject]).to eq(type: "ATMCard", id: "card-hold")
  end

  it "refuses a type outside the union" do
    runtime_with_subjects
    expect { place("h-2", "Customer", "c-hold") }.to raise_error(Hecks::Runtime::InvariantViolation, /SubjectType/)
  end

  it "refuses an id the named aggregate does not hold" do
    runtime_with_subjects
    expect { place("h-3", "Account", "card-hold") }.to raise_error(Hecks::Runtime::NotFound, /Account/)
  end

  it "is queryable by the type of its subject", :aggregate_failures do
    runtime = runtime_with_subjects
    place("h-4", "Account", "acct-hold")
    place("h-5", "ATMCard", "card-hold")
    expect(holds_on_cards(runtime).map { |hold| hold[:reference][:value] }).to eq(["h-5"])
  end

  it "branches on the subject's type through a given" do
    runtime_with_subjects
    hold = place("h-6", "ATMCard", "card-hold")
    expect { hold.escalate_account_hold! }.to raise_error(Hecks::Runtime::GivenNotMet)
  end

  describe "the declaration" do
    def union_domain(reference)
      proc do
        vision "x"
        generic
        instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)
        instance_exec(&READ_MODEL_ENTRY_AGGREGATE)
        aggregate("Tag") { instance_exec(&reference) }
      end
    end

    it "refuses a union with no name" do
      body = union_domain(proc { reference_to one_of(Account, Entry) })
      expect(&domain_build("NamelessUnion", body)).to raise_error(MALFORMED_UNION, /needs as:/)
    end

    it "refuses a union of one aggregate" do
      body = union_domain(proc { reference_to one_of(Account, Account), as: :subject })
      expect(&domain_build("ShortUnion", body)).to raise_error(MALFORMED_UNION, /two or more distinct/)
    end
  end
end
