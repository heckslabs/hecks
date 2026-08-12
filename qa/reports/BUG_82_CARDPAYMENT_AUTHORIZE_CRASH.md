# Bug #82: CardPayment.Authorize Expression Crash - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Command completely broken)  
**Type:** Expression Evaluation Bug (Systematic)

---

## The Bug

The CardPayment.Authorize command crashes during argument normalization with:
```
Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value" — no such attribute or argument
```

**Reproduction:**
```ruby
runtime.dispatch('Banking::CardPayment.Authorize',
  reference: { value: 'pay1' },
  account_id: acct.id,
  authorisation: { code: 'AUTH123' },
  amount: { cents: 5000, currency: 'USD' },
  merchant: { name: 'Test Merchant' },
  tags: { list: ['online'] }
)
# Hecksagain::Bluebook::Expression::EvaluationError: cannot resolve "value"
```

---

## Root Cause

The CardPayment.Authorize command contains:

```ruby
command "Authorize" do
  reference_to Account
  attribute :authorisation, AuthorisationCode
  attribute :amount, PaymentAmount
  attribute :merchant, MerchantName
  attribute :tags, list_of(Tag), optional: true
  then_set :amount, to: :amount           # <-- CRASHES
  then_set :merchant, to: :merchant       # <-- CRASHES
  then_set :tags, to: :tags               # <-- CRASHES
  emits "CardAuthorized"
end
```

Same pattern as Bugs #80 and #81.

---

## **SYSTEMATIC ISSUE: Third Instance Found**

This is the **THIRD INSTANCE** of the same systematic expression evaluator bug:

**Affected Commands So Far:**
1. SafeDepositBox.Rent (Bug #80)
2. ScheduledPayment.Schedule (Bug #81)
3. CardPayment.Authorize (Bug #82)

**Pattern:** Commands with `then_set :attr, to: :attr` where :attr requires parameter resolution crash during expression evaluation.

**Implication:** This is a **framework-wide bug** affecting multiple commands. Requires systematic audit and fix.

---

## Business Impact

**CRITICAL** - CardPayment.Authorize is completely non-functional. The entire card payment authorization feature is broken.

---

## Related Issues

- **Bug #80**: SafeDepositBox.Rent (same pattern)
- **Bug #81**: ScheduledPayment.Schedule (same pattern)
- Indicates widespread expression evaluator bug

---

## Next Steps

1. **Audit all commands** with `then_set :attr, to: :attr` pattern
2. **Fix expression resolver** to handle parameter references properly
3. **Test all affected commands** after fix

This is a framework-level defect requiring systematic remediation across multiple commands.
