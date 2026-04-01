# DomainDiff — Detect Changes Across Domain Versions

Compare two domain definitions and get every structural and behavioral change.

## Usage

```ruby
require "hecks"

old = Hecks.domain "Banking" do
  aggregate "Account" do
    attribute :name, String
    command("CreateAccount") { attribute :name, String }
    command("Deposit") { attribute :amount, Float }
    validation :name, presence: true
    policy("NotifyOnCreate") { on "CreatedAccount"; trigger "Deposit" }
  end
end

new_domain = Hecks.domain "Banking" do
  aggregate "Account" do
    attribute :name, String
    command("CreateAccount") { attribute :name, String }
    command("Withdraw") { attribute :amount, Float }
    validation :name, presence: true
    validation :balance, presence: true
    policy("FraudAlert") { on "Withdrew"; trigger "CreateAccount" }
  end
end

changes = Hecks::Migrations::DomainDiff.call(old, new_domain)
changes.each { |c| puts "#{c.kind}: #{c.details.inspect}" }
```

## Output

```
add_command: {:name=>"Withdraw"}
remove_command: {:name=>"Deposit"}
add_policy: {:name=>"FraudAlert", :event=>"Withdrew", :trigger=>"CreateAccount"}
remove_policy: {:name=>"NotifyOnCreate"}
add_validation: {:field=>:balance, :rules=>{:presence=>true}}
```

## What it detects

**Structural:** aggregates, attributes, value objects, entities, indexes

**Behavioral:** commands, policies (add/remove/changed wiring), validations, invariants, queries, scopes, subscribers, specifications
