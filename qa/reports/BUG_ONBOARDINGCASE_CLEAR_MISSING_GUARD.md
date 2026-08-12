# Bug #20: OnboardingCase.Clear Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1332-1339

## Problem

OnboardingCase.Clear command has no guard to enforce it only clears "screening" cases. The lifecycle declares `transition "Clear" => "cleared", from: "screening"` but the command lacks guards.

## Impact

- Can clear already-cleared cases
- Can clear declined cases
- KYC compliance audit corrupted
- Customer re-cleared without new screening

## Fix

Add guard to enforce status == "screening" before allowing clear.
