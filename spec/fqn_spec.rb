require "spec_helper"

RSpec.describe Hecks::Fqn do
  it "addresses a command with a PascalCase verb" do
    fqn = described_class.command(realm: "Acme", domain: "Banking", aggregate: "Account", command: "Credit")

    expect(fqn.to_s).to eq("Acme::Banking::Account.Credit")
    expect(fqn).to be_command
  end

  it "addresses a query with a snake_case verb" do
    fqn = described_class.query(realm: "Acme", domain: "Banking", aggregate: "Account", query: "in_good_standing")

    expect(fqn.to_s).to eq("Acme::Banking::Account.in_good_standing")
    expect(fqn).to be_query
  end

  it "pins a domain version on the domain segment" do
    fqn = described_class.parse("Acme::Banking@v2::Account.Credit")

    expect(fqn.realm).to eq("Acme")
    expect(fqn.domain).to eq("Banking")
    expect(fqn.version).to eq("v2")
    expect(fqn.aggregate).to eq("Account")
  end

  it "refuses an address whose verb cannot tell a command from a query" do
    expect { described_class.parse("Acme::Banking::Account.MixedCase_Query") }
      .to raise_error(Hecks::Fqn::Invalid, /PascalCase command or snake_case query/)
  end

  it "rejects malformed separators, empty segments, and invalid versions" do
    ["Acme::Banking::Account", ".Credit", "Acme::::Account.Credit", "Acme::Banking@::Account.Credit",
     "Acme::Banking@@v2::Account.Credit", "Acme::Banking@::Account.Credit", "Acme::Banking::Account."]
      .each do |text|
        expect { described_class.parse(text) }.to raise_error(described_class::Invalid), text
      end
  end

  it "rejects domain-level commands and invalid constructor segments" do
    expect { described_class.parse("Acme.Register") }
      .to raise_error(described_class::Invalid, /domain-level FQNs are query-only/)
    expect { described_class.command(realm: "Acme", domain: "Banking", aggregate: "Account", command: "bad") }
      .to raise_error(described_class::Invalid, /invalid verb/)
    expect { described_class.query(realm: "Acme", domain: "Banking", aggregate: "Account", query: "bad.query") }
      .to raise_error(described_class::Invalid, /cannot be empty or contain a separator/)
  end
end
