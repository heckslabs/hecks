# Bug #127: ScheduledPayment.Schedule Missing then_set :instruction

**Severity:** CRITICAL  
**Type:** Missing Attribute Persistence  

## Problem

ScheduledPayment.Schedule accepts an instruction attribute (used as the payment's identity) but never persists it.

## Fix

Add `then_set :instruction, to: :instruction`.
