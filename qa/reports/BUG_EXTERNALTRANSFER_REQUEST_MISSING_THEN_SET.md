# Bug #126: ExternalTransfer.Request Missing then_set :end_to_end

**Severity:** CRITICAL  
**Type:** Missing Attribute Persistence  

## Problem

ExternalTransfer.Request accepts an end_to_end attribute (used as the transfer's identity) but never persists it.

## Fix

Add `then_set :end_to_end, to: :end_to_end`.
