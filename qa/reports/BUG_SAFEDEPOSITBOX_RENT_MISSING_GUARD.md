# Bug #17: SafeDepositBox.Rent Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1217-1228

## Problem

SafeDepositBox.Rent command has no guard to enforce it only rents "vacant" boxes. The lifecycle declares `transition "Rent" => "rented", from: "vacant"` but the command lacks guards.

## Impact

- Can rent already-rented boxes to new customer
- Can rent surrendered-then-vacated boxes out of sequence
- Customer disputes on double-rent
- Vault access control corrupted

## Fix

Add guard to enforce status == "vacant" before allowing rent.
