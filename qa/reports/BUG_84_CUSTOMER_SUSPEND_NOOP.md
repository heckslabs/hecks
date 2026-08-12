# Bug #84: Customer.Suspend Allows No-Op Standing Change - HIGH

**Status:** IDENTIFIED  
**Severity:** HIGH (Business logic violation)  
**Type:** Missing Validation Predicate

---

## The Bug

Customer.Suspend command allows changing standing to the same value it already has (no-op operation).

**Evidence:**
```ruby
Customer initial standing: "good"
Suspend to: "good" ✓ (accepted - should fail, no change)
```

This violates the semantic meaning of "suspend" - the operation should actually change the standing, not remain the same.

---

## Root Cause

Customer.Suspend command has NO predicate validating that the new standing is different from the current standing.

**Command Definition:**
```ruby
command "Suspend" do
  reference_to Customer
  attribute :standing, CustomerStanding
  then_set :standing, to: :standing
  emits "CustomerSuspended"
end
```

No validation checking `standing != current_standing`.

---

## Business Impact

**HIGH** - Allows meaningless operations that don't actually suspend customers:
- Semantic violation of "suspend" operation
- Creates confusing audit trails (suspend operation with no effect)
- May indicate incomplete business logic

---

## Similar Pattern

This is part of the missing validation pattern:
- Operations that should change state allow no-op changes
- Predicates missing to validate state changes are meaningful

---

## Fix Required

Add predicate to Suspend command:
```ruby
given("suspend changes standing") { standing.value != current_standing.value }
```

Or alternatively, validate that standing is being set to "suspended" (if that's the intended behavior).

---

## Related Commands

**Reinstate** likely has the same issue - needs validation that standing actually changes from current value.

---

## Test Evidence

```
Test: Suspend good -> good (no-op)
Result: ✗ ACCEPTED (should reject - no meaningful change)

Test: Suspend good -> suspended (actual change)
Result: ✓ ACCEPTED (correct)
```
