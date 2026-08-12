# Bug #85: SafeDepositBox.IssueKey Expression Crash - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Command completely broken)  
**Type:** Expression Evaluation Bug (Systematic)

---

## The Bug

SafeDepositBox.IssueKey command crashes during argument normalization with:
```
Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value"
```

**Reproduction:**
```ruby
runtime.dispatch('Banking::SafeDepositBox.IssueKey',
  reference: { value: 'box1' },
  serial: { value: 'KEY123' }
)
# Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value"
```

---

## Root Cause

The IssueKey command contains:

```ruby
command "IssueKey" do
  reference_to SafeDepositBox
  attribute :serial, KeySerial
  then_set :keys, append: { serial: :serial }  # <-- CRASHES
  emits "KeyIssued"
end
```

When the expression evaluator processes `append: { serial: :serial }`, it crashes trying to resolve the `:serial` parameter reference.

---

## **SYSTEMATIC ISSUE: Fourth Instance Found**

This is the **FOURTH INSTANCE** of the same systematic expression evaluator bug:

**Affected Commands So Far:**
1. SafeDepositBox.Rent (Bug #80)
2. ScheduledPayment.Schedule (Bug #81)
3. CardPayment.Authorize (Bug #82)
4. SafeDepositBox.IssueKey (Bug #85) - NEW

**Pattern:** Commands with `then_set` expressions that reference command parameters crash during expression evaluation. The pattern includes:
- Direct parameter references: `then_set :size, to: :size`
- Nested parameter references: `then_set :keys, append: { serial: :serial }`

**Framework Impact:** This confirms a **widespread expression evaluator defect** affecting multiple commands and different then_set patterns.

---

## Business Impact

**CRITICAL** - SafeDepositBox.IssueKey is completely non-functional. Safe deposit box key management feature is broken.

---

## Related Issues

- **Bug #80**: SafeDepositBox.Rent then_set crash
- **Bug #81**: ScheduledPayment.Schedule then_set crash
- **Bug #82**: CardPayment.Authorize then_set crash
- Confirms systematic framework-wide bug

---

## Next Steps

Requires same fix as Bugs #80-82: Fix expression resolver to properly handle parameter references in then_set expressions.
