# Bug #129: Transfer.Request Missing Destination Account/Customer Validation

**Severity:** HIGH  
**Type:** Missing Cross-Aggregate Validation  

## Problem

Transfer.Request validates source account/customer status but not destination. Money can be transferred to closed or suspended customer accounts.

## Fix

Add guards:
- given("destination customer is active") { destination.customer.status == "active" }
- given("destination account is open") { destination.status == "open" }
