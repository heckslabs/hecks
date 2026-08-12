# Bug #72: TakeIn Command Money/Mark Type Mismatch

**Status:** IDENTIFIED

## The Bug

TakeIn command accepts a Money parameter (which allows zero cents), but appends to marks using Mark value object (which requires positive amounts), creating a type incompatibility that causes runtime invariant violations.

**Error:**
```
Mark invariant violated — a mark amount is positive (given {"amount":0,"direction":"in"})
```

## Root Cause

**TakeIn Command (till.bluebook:51-64):**
```ruby
command "TakeIn" do
  attribute :amount, Money  # allows cents >= 0
  then_set :marks, append: { amount: :amount, direction: "in" }  # uses Mark VO
end
```

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

**The Mismatch:**
- TakeIn accepts Money with `cents >= 0` (including zero)
- TakeIn appends to marks, converting amount to Mark
- Mark requires `amount > 0` (strictly positive)
- When TakeIn is called with zero cents, the append fails because Mark rejects zero

## Test Evidence

**Failed Test:** `spec/qa_bugs_spec.rb:337` - "Till Fixture - Adversarial Testing accepts zero amount in TakeIn"

The test correctly expects TakeIn to accept zero amounts (Money allows it), but the command fails when trying to create the Mark VO with zero amount.

## Possible Fixes

**Option 1:** Make TakeIn reject zero amounts (add given() predicate)
```ruby
command "TakeIn" do
  given("a taking is a positive amount") { amount.cents.positive? }
  ...
end
```

**Option 2:** Allow zero in Mark invariant
```ruby
invariant("a mark amount is non-negative") { amount >= 0 }
```

**Option 3:** Use different VO for marks that allows zero
- Create MoneyChange VO with `cents >= 0`
- Use that in marks instead of Mark

**Recommended:** Option 1 (add predicate) - Taking zero doesn't make semantic sense anyway

## Semantic Analysis

From the view perspective:
- Taking in zero money = no-op, doesn't make business sense
- The test might be checking "doesn't crash on zero" rather than "accepts zero as valid"
- Mark records a transaction, and zero transaction shouldn't be recorded

Recommendation: Add `given("a taking is a positive amount") { amount.cents.positive? }` to TakeIn command to reject zero amounts at the predicate level before hitting the invariant mismatch.

## Impact

- Till fixture is part of the test suite
- Currently failing with InvariantViolation instead of GivenNotMet
- Semantically incorrect error message (invariant instead of business rule)

## Pattern

This is the inverse of type-mismatch bugs: the command's input type is too permissive for the output type it's building. The fix is to restrict the input via predicates, not change the invariants.
