# Bug #80: SafeDepositBox.Rent then_set Expression Crash - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Command completely broken)  
**Type:** Expression Evaluation Bug

---

## The Bug

The SafeDepositBox.Rent command crashes immediately upon invocation during argument normalization:

```
Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value" — no such attribute or argument
```

### Reproduction Steps

```ruby
cust = runtime.dispatch('Banking::Customer.Register',
  reference: { value: 'c1' },
  name: { given: 'John', family: 'Doe' },
  email: { address: 'john@example.com' }
)

box = runtime.dispatch('Banking::SafeDepositBox.Create',
  reference: { value: 'box1' },
  branch_code: { code: 'NYC01' },
  box_number: { number: '001' }
)

# This CRASHES
runtime.dispatch('Banking::SafeDepositBox.Rent',
  reference: { value: 'box1' },
  customer_id: cust.id,
  size: 'small'
)
# Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value"
```

---

## Root Cause

The SafeDepositBox.Rent command contains:

```ruby
command "Rent" do
  reference_to SafeDepositBox
  reference_to Customer
  attribute :size, Size  # Size is synthesized one_of VO
  then_set :size, to: :size  # <-- BROKEN
  emits "BoxRented"
end
```

Where Size is:
```ruby
attribute :size, one_of("small", "medium", "large"), default: { value: "small" }
```

**The Problem:**
The `then_set :size, to: :size` expression tries to reference the command parameter `:size`, which is a synthesized one_of value object. When the expression evaluator tries to coerce this reference, it fails:

1. Expression evaluator processes `to: :size` 
2. Tries to resolve `:size` to the command parameter
3. Attempts to access internal structure of synthesized one_of VO
4. Fails with "cannot resolve 'value'" (trying to access `.value` property)
5. **Crash: InvariantViolation never reached, command never executes**

---

## Stack Trace

```
from /lib/hecksagain/bluebook/expression/resolver.rb:224:in `fetch'
  cannot resolve "value" — no such attribute or argument

from /lib/hecksagain/runtime/value/coercion.rb:73:in `block in build'
from /lib/hecksagain/runtime/value/coercion.rb:39:in `for_attribute'
from /lib/hecksagain/runtime/interpreting.rb:54:in `coerce_declared_arguments'
from /lib/hecksagain/runtime/interpreting.rb:65:in `normalize_args'
from /lib/hecksagain/runtime/command_interpreter.rb:64:in `step_normalize_args'
```

---

## Business Impact

**CRITICAL** - The SafeDepositBox.Rent command is 100% non-functional. No safe deposit boxes can be rented. This is a complete feature failure.

---

## Why This Escaped Prior Testing

Bug #71 (SafeDepositBox.Rent missing `reference_to SafeDepositBox`) was fixed in the previous QA session. That fix made the command syntactically valid but didn't test the actual runtime execution. The then_set expression bug only manifests at runtime during argument normalization.

---

## Fix Required

### Option 1: Simplify to Auto-Assignment
Remove the then_set and rely on auto-assignment (most commands use this pattern):

```ruby
command "Rent" do
  reference_to SafeDepositBox
  reference_to Customer
  attribute :size, Size
  # Remove: then_set :size, to: :size
  # The :size attribute is auto-assigned to aggregate
  emits "BoxRented"
end
```

### Option 2: Use Explicit Value Access
If the then_set is intentionally different from auto-assignment, use explicit value:

```ruby
attribute :size, Size
then_set :size, increment: { value: { category: :size } }  # or similar
```

### Option 3: Use Hand-Declared VO
Replace synthesized one_of with hand-declared:

```ruby
attribute :size, BoxSize  # Hand-declared VO instead of one_of
then_set :size, to: :size
```

---

## Test Evidence

**Before Fix:**
```
SafeDepositBox.Rent => Hecksagain::Bluebook::Expression::EvaluationError
```

**After Fix (would be):**
```
SafeDepositBox.Rent => Successfully rents box with given size
```

---

## Related Issues

- **Bug #71** (prior QA session): SafeDepositBox.Rent missing `reference_to` - FIXED
- **Bugs #77, #78**: one_of validation framework issues
- This bug: Synthesized one_of VO not compatible with expression resolution in then_set context

---

## Severity Assessment

**CRITICAL** because:
- ✗ Command is 100% broken (crashes on every invocation)
- ✗ No workaround possible (command doesn't exist)
- ✗ Blocks entire SafeDepositBox rental feature
- ✗ Reveals framework bug in expression resolution for synthesized VOs
