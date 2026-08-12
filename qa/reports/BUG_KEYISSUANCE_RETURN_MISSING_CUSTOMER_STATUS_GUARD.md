# Bug #118: KeyIssuance.Return Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

KeyIssuance.Return (nested entity in SafeDepositBox) should check customer is active before returning a key.

## Fix

Add customer.status == "active" guard via parent.customer.
