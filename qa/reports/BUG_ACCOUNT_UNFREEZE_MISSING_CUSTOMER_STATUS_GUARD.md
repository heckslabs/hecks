# Bug #73: Account.Unfreeze Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Account.Unfreeze should check customer is active before unfreezing.

## Fix

Add customer.status == "active" guard.
