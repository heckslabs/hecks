# Bug #29: OnboardingCase.Decline Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1350-1357

## Problem

OnboardingCase.Decline command has no guard to enforce it only declines "screening" cases. The lifecycle declares `transition "Decline" => "declined", from: "screening"` but the command lacks guards.

## Impact

- Can decline already-declined cases
- Can decline cleared cases
- KYC compliance audit corrupted
- Customer record corrupted

## Fix

Add guard to enforce status == "screening" before allowing decline.
