# Bug #81: ScheduledPayment.Schedule then_set Expression Crash - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Command completely broken)  
**Type:** Expression Evaluation Bug (Systematic issue)

---

## The Bug

The ScheduledPayment.Schedule command crashes during argument normalization with:
```
Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value" — no such attribute or argument
```

**Reproduction:**
```ruby
runtime.dispatch('Banking::ScheduledPayment.Schedule',
  reference: { value: 'sched1' },
  account_id: acct.id,
  instruction: { reference: 'instr1' },
  amount: { cents: 5000, currency: 'USD' },
  recipient: { name: 'John Doe', account: 'acct2' },
  due_on: { date: '2026-12-31' }
)
# Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value"
```

---

## Root Cause

The ScheduledPayment.Schedule command contains:

```ruby
command "Schedule" do
  reference_to Account
  attribute :instruction, InstructionReference
  attribute :amount, ScheduledAmount
  attribute :recipient, PaymentRecipient
  attribute :due_on, PaymentDueDate
  then_set :amount, to: :amount      # <-- CRASHES
  then_set :recipient, to: :recipient # <-- CRASHES  
  then_set :due_on, to: :due_on       # <-- CRASHES
  emits "PaymentScheduled"
end
```

When the expression evaluator processes `then_set :amount, to: :amount`, it tries to:
1. Resolve `:amount` to the command parameter
2. Access the internal structure of the ScheduledAmount VO
3. Fails with "cannot resolve 'value'" - trying to access `.value` property

---

## **SYSTEMATIC ISSUE: Not Just SafeDepositBox**

This is the **SAME BUG PATTERN as Bug #80** (SafeDepositBox.Rent), indicating a **framework-level bug** in how the expression evaluator handles certain types of value objects in then_set context.

**Commands affected so far:**
- SafeDepositBox.Rent (Bug #80)
- ScheduledPayment.Schedule (Bug #81)

**Pattern:** Commands with `then_set :attr, to: :attr` where :attr is a complex VO that needs parameter reference resolution

---

## Business Impact

**CRITICAL** - The ScheduledPayment.Schedule command is 100% non-functional. No scheduled payments can be created. This breaks the entire payment scheduling feature.

---

## Comparison to Bug #80

**Similarity:**
- Both use `then_set :attr, to: :attr` pattern
- Both crash during argument normalization
- Both fail with "cannot resolve 'value'" error
- Both affect complex VOs

**Difference:**
- Bug #80: Synthesized one_of VO (Size)
- Bug #81: Complex hand-declared VOs (ScheduledAmount, PaymentRecipient)

**Implication:** Bug in expression resolver is broader than just synthesized VOs - affects multiple types of parameter references in then_set

---

## Fix Required

**Same as Bug #80:** Either:
1. Remove problematic then_set expressions
2. Use explicit value access syntax
3. Fix expression resolver to handle parameter references properly

---

## Related Issues

- **Bug #80**: SafeDepositBox.Rent then_set crash (same pattern)
- This bug: ScheduledPayment.Schedule then_set crash (same pattern)

**Framework-level investigation needed:** Why does `then_set :attr, to: :attr` fail for certain types of value objects?
