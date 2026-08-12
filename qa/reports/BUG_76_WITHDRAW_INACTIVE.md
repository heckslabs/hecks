# Bug #76: ATMCard.Withdraw Allows Withdrawals From Inactive Card

**Status:** IDENTIFIED

## The Bug

ATMCard.Withdraw command allows cash withdrawals even when the card is in "issued" state (not activated).

**Evidence:**
```ruby
# Card issued but NOT activated (status = "issued")
card = runtime.dispatch('Banking::ATMCard.Issue', ...)
# No Activate call

# Yet withdrawal succeeds!
result = runtime.dispatch('Banking::ATMCard.Withdraw',
  serial: { value: 'CARD001' },
  cents: { cents: 1000 },
  narrative: { text: 'Unauthorized' }
)
# Result: Withdrawal appended even though card.status == "issued"
```

## Root Cause

The Withdraw command has no lifecycle predicate to check that the card is in "active" state before allowing withdrawals.

**Withdraw Command Structure:**
```ruby
command "Withdraw" do
  role "Customer"
  goal "Take cash out at a machine"

  reference_to ATMCard
  attribute :cents,     WithdrawalAmount
  attribute :narrative, Narrative

  then_set :withdrawals, append: { cents: :cents, narrative: :narrative }
  # NO PREDICATE CHECKING status == "active"

  emits "CashWithdrawn"
end
```

## File Location

`examples/banking/bluebook/banking.bluebook`

## The Fix

Add a lifecycle predicate:

```ruby
command "Withdraw" do
  role "Customer"
  goal "Take cash out at a machine"

  reference_to ATMCard
  attribute :cents,     WithdrawalAmount
  attribute :narrative, Narrative

  given("card must be active") { status == "active" }

  then_set :withdrawals, append: { cents: :cents, narrative: :narrative }

  emits "CashWithdrawn"
end
```

## Business Impact

HIGH - Security vulnerability: customers can withdraw cash from cards that haven't been activated/authorized yet.

## Related Bugs

- Bug #73 (ATMCard.Retire from wrong state) - related state machine issues

