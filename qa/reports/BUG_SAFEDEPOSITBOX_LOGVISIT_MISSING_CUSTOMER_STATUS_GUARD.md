# Bug #76: SafeDepositBox.LogVisit Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

SafeDepositBox.LogVisit should check customer is active before logging a box visit.

## Fix

Add customer.status == "active" guard.
