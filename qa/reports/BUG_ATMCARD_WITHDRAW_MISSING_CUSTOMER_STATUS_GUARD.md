# Bug #106: ATMCard.Withdraw Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ATMCard.Withdraw should check customer is active before withdrawing cash.

## Fix

Add customer.status == "active" guard.
