# Bug #105: ATMCard.Issue Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ATMCard.Issue should check customer is active before issuing a card.

## Fix

Add customer.status == "active" guard.
