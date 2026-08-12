# Bug #75: Till.TakeIn Accepts Zero Amounts

**Status:** IDENTIFIED

## The Bug

The TakeIn command accepts zero amounts when semantically a "taking in" of zero money is a no-op and should be rejected.

## Root Cause

Money VO allows zero (cents >= 0), but Mark VO (used to record the transaction) requires positive amounts (amount > 0). This creates a type mismatch.

**Money VO (till.bluebook:25-28):**
```ruby
value_object "Money" do
  attribute :cents, Integer
  invariant("a cash amount is never negative") { cents >= 0 }  # allows zero
end
```

**Mark VO (till.bluebook:30-35):**
```ruby
value_object "Mark" do
  attribute :amount, Integer
  invariant("a mark amount is positive") { amount.positive? }  # requires > 0
end
```

**TakeIn Command (till.bluebook:51-64):**
```ruby
command "TakeIn" do
  reference_to Room
  attribute :amount, Money  # allows cents >= 0
  then_set :marks, append: { amount: :amount, direction: "in" }  # uses Mark VO which requires > 0
end
```

## The Fix

Add a predicate to TakeIn to reject zero amounts:

```ruby
command "TakeIn" do
  reference_to Room
  attribute :amount, Money

  given("a taking must be a positive amount") { amount.cents.positive? }

  then_set :marks, append: { amount: :amount, direction: "in" }
end
```

## Test Case

```ruby
room = runtime.dispatch('Till::Room.CreateRoom', name: { value: 'Till1' })

# Should fail but currently crashes with invariant violation
runtime.dispatch('Till::Room.TakeIn',
  name: room.id,
  amount: { cents: 0 }
)
# Error: Mark invariant violated — a mark amount is positive (given {"amount":0,"direction":"in"})
```

