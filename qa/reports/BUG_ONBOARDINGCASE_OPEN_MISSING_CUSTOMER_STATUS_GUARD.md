# Bug #42: OnboardingCase.Open Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1338-1350

## Problem

OnboardingCase.Open command references a Customer but has no guard to enforce the customer is "active". KYC cases should only be opened for active customers, not suspended or closed ones.

## Impact

- Can open onboarding cases for suspended customers
- Can open onboarding cases for closed customers
- Suspended customer gains new account access
- KYC compliance audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing case opening.
