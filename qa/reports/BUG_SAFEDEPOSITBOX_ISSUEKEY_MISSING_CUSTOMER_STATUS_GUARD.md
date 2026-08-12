# Bug #77: SafeDepositBox.IssueKey Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

SafeDepositBox.IssueKey should check customer is active before issuing a key.

## Fix

Add customer.status == "active" guard.
