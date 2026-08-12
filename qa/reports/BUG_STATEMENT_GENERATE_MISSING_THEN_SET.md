# Bug #124: Statement.Generate Missing then_set

**Severity:** CRITICAL  
**Type:** Missing Attribute Persistence  

## Problem

Statement.Generate accepts 5 attributes (period, opening_balance, closing_balance, generated_on, frequency) but persists NONE of them to the statement record.

## Fix

Add then_set statements for all 5 attributes:
- then_set :period, to: :period
- then_set :opening_balance, to: :opening_balance
- then_set :closing_balance, to: :closing_balance
- then_set :generated_on, to: :generated_on
- then_set :frequency, to: :frequency
