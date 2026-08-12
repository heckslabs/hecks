# Bug #75: SafeDepositBox.Surrender Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

SafeDepositBox.Surrender should check customer is active before surrendering a box.

## Fix

Add customer.status == "active" guard.
