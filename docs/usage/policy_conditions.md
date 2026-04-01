# Policy Conditions

A reactive policy can have a `condition` block that controls when it fires. The block receives the event and must return true for the policy to trigger.

## Usage

```ruby
Hecks.domain "Banking" do
  aggregate "Account" do
    attribute :balance, Float

    command "Withdraw" do
      attribute :account_id, String
      attribute :amount, Float
    end

    command "FlagSuspicious" do
      attribute :account_id, String
    end

    # Only flag withdrawals over $10,000
    policy "FraudAlert" do
      on "Withdrew"
      trigger "FlagSuspicious"
      map account_id: :account_id
      condition { |event| event.amount > 10_000 }
    end
  end
end
```

## Behavior

```ruby
# Small withdrawal — policy does NOT fire
Account.withdraw(account_id: acct.id, amount: 500.0)
# => Withdrew event, no FraudAlert

# Large withdrawal — policy fires
Account.withdraw(account_id: acct.id, amount: 25_000.0)
# => Withdrew event
# => Policy: FraudAlert -> FlagSuspicious
```

## No condition = always fires

Policies without a `condition` block fire on every matching event:

```ruby
policy "NotifyOnDeposit" do
  on "Deposited"
  trigger "SendReceipt"
end
# Fires on every Deposited event
```
