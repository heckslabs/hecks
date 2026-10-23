require "spec_helper"

# PlainEnglish speaks a command as the act of doing it, which every statement and action term reads.
RSpec.describe Hecks::Projections::PlainEnglish do
  DOINGS = {
    %w[AddTopping Order]        => "adding a topping",
    %w[Purchase Order]          => "purchasing an order",
    %w[LogVisit SafeDepositBox] => "logging a visit",
    %w[AccrueInterest Account]  => "accruing interest",
    %w[Debited Transfer]        => "marking a transfer debited",
    %w[Chargeback CardPayment]  => "charging back a card payment",
    %w[Withdraw ATMCard]        => "withdrawing from an ATM card",
    %w[Submit Claim]            => "submitting a claim",
    %w[Issue ATMCard]           => "issuing an ATM card",
    %w[Open Account]            => "opening an account"
  }.freeze

  DOINGS.each do |(command, holder), said|
    it "says #{command} on #{holder} as \"#{said}\"" do
      expect(described_class.doing(command, holder)).to eq(said)
    end
  end

  it "keeps an acronym's capitals in a noun" do
    expect(described_class.noun("ATMCard")).to eq("ATM card")
  end
end
