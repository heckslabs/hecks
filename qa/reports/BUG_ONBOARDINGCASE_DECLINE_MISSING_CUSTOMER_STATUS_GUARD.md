# Bug #79: OnboardingCase.Decline Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

OnboardingCase.Decline should check customer is active before declining a case.

## Fix

Add customer.status == "active" guard.
