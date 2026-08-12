# Bug #86: ExternalTransfer.Send Missing Customer/Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ExternalTransfer.Send should check customer is active and account is open before sending a transfer.

## Fix

Add customer.status == "active" and account.status == "open" guards.
