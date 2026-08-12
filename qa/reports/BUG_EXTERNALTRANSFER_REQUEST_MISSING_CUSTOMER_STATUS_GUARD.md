# Bug #85: ExternalTransfer.Request Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ExternalTransfer.Request should check customer is active before requesting an external transfer.

## Fix

Add customer.status == "active" guard.
