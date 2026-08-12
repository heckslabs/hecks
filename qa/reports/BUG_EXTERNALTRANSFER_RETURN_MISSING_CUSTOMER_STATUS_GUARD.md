# Bug #88: ExternalTransfer.Return Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ExternalTransfer.Return should check customer is active before processing a return.

## Fix

Add customer.status == "active" guard.
