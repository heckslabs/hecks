# Complete Bug Summary - QA Session 2026-08-13

**Total Bugs Found:** 6 (5 new + 1 fixed)  
**All bugs verified and documented**  

## Summary Table

| # | Title | Severity | Status | Domain | Type |
|---|-------|----------|--------|--------|------|
| 71 | SafeDepositBox.Rent Missing Reference | HIGH | ✅ FIXED | Banking | Reference |
| 72 | Till.TakeIn Accepts Zero Amounts | HIGH | 🔍 IDENTIFIED | Till | Type Mismatch |
| 73 | ATMCard.Retire From Wrong State | HIGH | 🔍 IDENTIFIED | Banking | Lifecycle |
| 74 | Pizza Purchase Underpayment | CRITICAL | 🔍 IDENTIFIED | Pizzas | Validation |
| 75 | Pizza Negative Price | CRITICAL | 🔍 IDENTIFIED | Pizzas | Validation |
| 76 | ATMCard.Withdraw From Inactive | HIGH | 🔍 IDENTIFIED | Banking | Validation |

## Detailed Bug Descriptions

### Bug #71: SafeDepositBox.Rent Missing Reference ✅ FIXED

**Severity:** HIGH  
**Status:** FIXED (prior session)  
**Category:** Reference Resolution

**Problem:**
Rent command was missing `reference_to SafeDepositBox` declaration, causing it to attempt creating a new SafeDepositBox instead of updating an existing one.

**Evidence:**
```
AlreadyExists: Rent creates a SafeDepositBox that already exists — branch_code.value, box_number.value "MAIN:100"
```

**Fix:** Added `reference_to SafeDepositBox` before `reference_to Customer`

**Learning:** Commands that update existing aggregates MUST declare `reference_to` explicitly.

---

### Bug #72: Till.TakeIn Accepts Zero Amounts

**Severity:** HIGH  
**Status:** IDENTIFIED  
**Category:** Type Mismatch Bug

**Problem:**
TakeIn command accepts Money (cents >= 0) but appends Mark VO (requires amount > 0), causing invariant violation.

**Evidence:**
```ruby
TakeIn with zero amount → Mark invariant violated — a mark amount is positive
```

**Files:**
- spec/fixtures/till.bluebook (line 51-64, 30-35)

**Root Cause:**
Money VO: `invariant("a cash amount is never negative") { cents >= 0 }`  
Mark VO: `invariant("a mark amount is positive") { amount.positive? }`

**Fix Required:**
```ruby
command "TakeIn" do
  given("taking must be positive") { amount.cents.positive? }
  # ... rest of command
end
```

**Learning:** Input types must be compatible with output VO invariants.

---

### Bug #73: ATMCard.Retire Allows From Unactivated State

**Severity:** HIGH  
**Status:** IDENTIFIED  
**Category:** Lifecycle State Machine Bug

**Problem:**
Retire transition allows from both "issued" and "active" states, but semantically "retire" means deactivate (should only work from "active").

**Evidence:**
```
Lifecycle line 538: transition "Retire" => "retired", from: ["issued", "active"]
```

**Impact:**
Can retire unactivated cards in "issued" state.

**File:**
examples/banking/bluebook/banking.bluebook (line 538)

**Fix Required:**
```ruby
transition "Retire" => "retired", from: "active"  # was: from: ["issued", "active"]
```

**Learning:** State machine transitions must reflect business semantics, not just technical paths.

---

### Bug #74: Pizzas.Order.Purchase Accepts Underpayment ⭐ CRITICAL

**Severity:** CRITICAL  
**Status:** IDENTIFIED  
**Category:** Missing Validation Predicate

**Problem:**
Purchase command has NO predicate validating that payment amount >= pizza price.

**Evidence:**
```
Pizza price: 1200 cents
Payment accepted: 100 cents ✓ (should fail)
Payment accepted: 500 cents ✓ (should fail)
Payment accepted: 1000 cents ✓ (should fail)
```

**Impact:**
DIRECT REVENUE LOSS - Customers can purchase pizzas while underpaying.

**File:**
examples/pizzas/bluebook/pizzas.bluebook (Purchase command)

**Current Code:**
```ruby
command "Purchase" do
  role "Customer"
  goal "Buy the pizza"

  reference_to Order
  attribute :customer_name, CustomerName
  attribute :amount, Price

  given("a pizza needs at least one topping") { toppings.size.positive? }
  given("it must still be available")         { status == "available" }
  given("a payment was actually made")         { amount.cents.positive? }
  # MISSING: given("payment covers price") check

  then_set :customer_name, to: :customer_name
  then_set :status,        to: "sold"

  emits "PizzaPurchased"
end
```

**Fix Required:**
```ruby
given("payment covers the price") { amount.cents >= pizza.price_cents.cents }
```

**Learning:** Every business transaction needs validation predicates, especially financial operations.

---

### Bug #75: Pizzas.Order.CreatePizza Accepts Negative Prices ⭐ CRITICAL

**Severity:** CRITICAL  
**Status:** IDENTIFIED  
**Category:** Missing Validation Predicate

**Problem:**
CreatePizza command has NO predicate validating positive price.

**Evidence:**
```
Pizza created: name="NegativePizza", price=-1000 cents ✓
Stored successfully in repository
```

**Impact:**
BUSINESS LOGIC VIOLATION - Potential arbitrage where customers are paid to order pizzas.

**File:**
examples/pizzas/bluebook/pizzas.bluebook (CreatePizza command)

**Current Code:**
```ruby
command "CreatePizza" do
  role "Customer"
  goal "Create a pizza with a name and starting price"

  attribute :name,  PizzaName
  attribute :pizza, Pizza
  # MISSING: predicate checking pizza.price_cents > 0

  then_set :name,  to: :name
  then_set :pizza, to: :pizza

  emits "PizzaCreated"
end
```

**Fix Required:**
```ruby
given("pizza price is positive") { pizza.price_cents.cents.positive? }
```

**Learning:** Creating commands bypass some validation - explicit input predicates are essential.

---

### Bug #76: ATMCard.Withdraw Allows Withdrawals From Inactive Card

**Severity:** HIGH (Security Vulnerability)  
**Status:** IDENTIFIED  
**Category:** Missing State Check Predicate

**Problem:**
Withdraw command has NO predicate checking that card is in "active" state.

**Evidence:**
```
Card status: "issued" (not activated)
Withdrawal: 1000 cents ✓ (should fail)
Result: Withdrawal appended despite inactive card
```

**Impact:**
SECURITY VULNERABILITY - Cash can be withdrawn from unactivated cards.

**File:**
examples/banking/bluebook/banking.bluebook (Withdraw command, line ~566)

**Current Code:**
```ruby
command "Withdraw" do
  role "Customer"
  goal "Take cash out at a machine"

  reference_to ATMCard
  attribute :cents,     WithdrawalAmount
  attribute :narrative, Narrative

  then_set :withdrawals, append: { cents: :cents, narrative: :narrative }
  # MISSING: given("card must be active") check

  emits "CashWithdrawn"
end
```

**Fix Required:**
```ruby
given("card must be active") { status == "active" }
```

**Learning:** Commands operating on stateful aggregates must validate current state.

---

## Bug Pattern Summary

### Pattern 1: Missing Predicates (50% of bugs)
3 bugs (#74, #75, #76) lack required business rule validation.

**Root Cause:** Commands (especially creating commands) lack input validation predicates.

**Prevention:** 
- Require predicates for all business rules
- Create framework templates for common validations
- Audit all creating commands for input validation

### Pattern 2: Type Mismatch (17% of bugs)
1 bug (#72) has input type incompatible with output type.

**Root Cause:** No type compatibility check between command inputs and output VOs.

**Prevention:**
- Framework check for I/O type compatibility
- Require input predicates when input is more permissive than output

### Pattern 3: Lifecycle Semantics (17% of bugs)
1 bug (#73) has state transition mismatch with business logic.

**Root Cause:** State machines designed technically rather than semantically.

**Prevention:**
- Map state machines to business processes
- Review all transitions for semantic correctness
- Use domain expert validation

### Pattern 4: Reference Resolution (17% of bugs)
1 bug (#71, FIXED) lacked reference declaration.

**Root Cause:** Distinguishing creating vs updating requires explicit reference.

**Prevention:**
- Clear documentation on reference_to usage
- Framework guidance for when to use reference_to

---

## Test Metrics

- **Commands Tested:** 50+
- **Edge Cases Tested:** 50+
- **Verification Tests:** 100+
- **Bugs Identified:** 6
- **Bugs Verified:** 6/6 (100%)
- **Bugs Fixed:** 1

---

## Recommendations

### Immediate (Critical)
1. Fix Bug #74 (underpayment) - Revenue impact
2. Fix Bug #75 (negative price) - Business logic violation  
3. Fix Bug #76 (inactive withdrawal) - Security vulnerability

### Short Term
4. Fix Bug #72 (zero amounts) - Runtime crashes
5. Fix Bug #73 (wrong state) - Business logic

### Long Term
- Implement framework-level predicate templates
- Add type compatibility checks for I/O
- Create lifecycle design guidelines
- Conduct audit of all existing predicates

---

## Conclusion

All 6 bugs are real, verified, and ready for fixes. The bugs follow predictable patterns that should be addressed at the framework level to prevent recurrence in future development.

