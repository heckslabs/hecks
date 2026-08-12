# Bug #94: Transfer.Reject Missing Source Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Transfer.Reject should check source customer is active before rejecting a transfer.

## Fix

Add source.customer.status == "active" guard.
