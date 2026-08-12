# Bug #78: OnboardingCase.Clear Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

OnboardingCase.Clear should check customer is active before clearing a case.

## Fix

Add customer.status == "active" guard.
