# Bug #91: Transfer.Settle Missing Destination Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Transfer.Settle should check destination customer is active before recording settlement.

## Fix

Add destination.customer.status == "active" guard.
