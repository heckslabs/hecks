# Bug #89: Transfer.Request Missing Source Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Transfer.Request should check source customer is active before initiating a transfer.

## Fix

Add source.customer.status == "active" guard.
