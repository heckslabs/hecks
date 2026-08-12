# Bug #79: Banking.Account.Credit Ignores Daily Limit

**Status:** IDENTIFIED

## The Bug

Account.Credit command accepts amounts larger than the account's daily_limit, while Account.Debit correctly enforces it.

**Evidence:**
```ruby
Account daily_limit: 1000 cents

Credit Tests:
- Credit 500: ACCEPTED ✓
- Credit 600: ACCEPTED ✓
- Credit 700: ACCEPTED ✓
- Total: 1800 cents (exceeds 1000 limit) ✗

Debit Test:
- Debit 1001: REJECTED ✓ (correctly enforced)
```

## Root Cause

Credit command has NO predicate validating `amount <= daily_limit`, while Debit correctly validates it.

## Asymmetry

- **Debit:** daily_limit IS enforced ✓
- **Credit:** daily_limit NOT enforced ✗

## File Location

examples/banking/bluebook/banking.bluebook (Credit command definition)

## Business Impact

HIGH (Security vulnerability) - Asymmetric validation allows bypassing daily_limit by using Credit instead of Debit.

## Semantic Issue

Daily limits are meant to control daily transaction amounts (both in and out). Credit ignoring this creates a security loophole.

## Fix Required

Add predicate to Credit command:
```ruby
given("transaction respects daily limit") { amount.cents <= daily_limit.cents }
```

