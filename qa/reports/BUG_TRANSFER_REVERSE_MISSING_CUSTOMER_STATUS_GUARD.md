# Bug #93: Transfer.Reverse Missing Source Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Transfer.Reverse should check source customer is active before reversing a transfer.

## Fix

Add source.customer.status == "active" guard.
