#!/usr/bin/env ruby
#
# Working banking domain — structure in Bluebook, logic in generated files.
#
# Run from the hecks project root:
#   ruby -Ilib examples/banking/app.rb
#
require "hecks"
require "ostruct"

app = Hecks.boot(__dir__)

puts "=== Banking Domain ==="

# --- Event subscriptions ---

app.on("OpenedAccount") { |e| puts "  [event] Opened #{e.account_type} account" }
app.on("Deposited") { |e| puts "  [event] Deposited $#{"%.2f" % e.amount}" }
app.on("Withdrew") { |e| puts "  [event] Withdrew $#{"%.2f" % e.amount}" }
app.on("CompletedTransfer") { |e| puts "  [event] Transfer completed" }
app.on("IssuedLoan") { |e| puts "  [event] Loan issued: $#{"%.2f" % e.principal} at #{e.rate}%" }
app.on("MadePayment") { |e| puts "  [event] Payment: $#{"%.2f" % e.amount}" }
app.on("DefaultedLoan") { |e| puts "  [event] Loan defaulted" }
app.on("SuspendedCustomer") { |e| puts "  [event] Customer suspended" }

# --- Run the scenario ---

puts "\n--- Register customers ---"
alice = Customer.register(name: "Alice Johnson", email: "alice@example.com")
bob = Customer.register(name: "Bob Smith", email: "bob@example.com")
puts "#{alice.name} (#{alice.status})"
puts "#{bob.name} (#{bob.status})"

puts "\n--- Open accounts ---"
checking = Account.open(customer_id: alice.id, account_type: "checking", daily_limit: 5000.0)
savings = Account.open(customer_id: alice.id, account_type: "savings", daily_limit: 10000.0)
bob_acct = Account.open(customer_id: bob.id, account_type: "checking", daily_limit: 3000.0)

puts "\n--- Deposits ---"
Account.deposit(account_id: checking.id, amount: 5000.0)
Account.deposit(account_id: savings.id, amount: 10000.0)
Account.deposit(account_id: bob_acct.id, amount: 2000.0)
checking = Account.find(checking.id)
savings = Account.find(savings.id)
bob_acct = Account.find(bob_acct.id)
puts "Alice checking: $#{"%.2f" % checking.balance}"
puts "Alice savings:  $#{"%.2f" % savings.balance}"
puts "Bob checking:   $#{"%.2f" % bob_acct.balance}"

puts "\n--- Withdraw $1,500 from checking ---"
checking = Account.withdraw(account_id: checking.id, amount: 1500.0)
puts "Alice checking: $#{"%.2f" % checking.balance}"

puts "\n--- Overdraft protection ---"
begin
  Account.withdraw(account_id: checking.id, amount: 99999.0)
rescue => e
  puts "Blocked: #{e.message}"
end

puts "\n--- Daily limit ---"
begin
  Account.withdraw(account_id: checking.id, amount: 4000.0)
rescue => e
  puts "Blocked: #{e.message}"
end

puts "\n--- Transfer $500: Alice -> Bob ---"
xfer = Transfer.initiate(from_account_id: checking.id, to_account_id: bob_acct.id, amount: 500.0, memo: "Dinner last week")
puts "Transfer: $#{"%.2f" % xfer.amount} (#{xfer.status}) — #{xfer.memo}"
xfer = Transfer.complete(transfer_id: xfer.id)
puts "Transfer: #{xfer.status}"
checking = Account.find(checking.id)
bob_acct = Account.find(bob_acct.id)
puts "Alice checking: $#{"%.2f" % checking.balance}"
puts "Bob checking:   $#{"%.2f" % bob_acct.balance}"

puts "\n--- Issue loan: $25,000 at 5.25% for 60 months ---"
loan = Loan.issue(customer_id: alice.id, account_id: checking.id, principal: 25000.0, rate: 5.25, term_months: 60)
puts "Remaining: $#{"%.2f" % loan.remaining_balance}"
checking = Account.find(checking.id)
puts "Alice checking after disbursement: $#{"%.2f" % checking.balance}"

puts "\n--- Make 3 loan payments of $450 ---"
3.times do |i|
  loan = Loan.make_payment(loan_id: loan.id, amount: 450.0)
  puts "Payment #{i + 1}: remaining $#{"%.2f" % loan.remaining_balance}"
end

puts "\n--- Bob defaults on his loan ---"
bad_loan = Loan.issue(customer_id: bob.id, account_id: bob_acct.id, principal: 10000.0, rate: 12.0, term_months: 24)
bad_loan = Loan.default(loan_id: bad_loan.id, customer_id: bob.id)
puts "Loan status: #{bad_loan.status}"
bob = Customer.find(bob.id)
puts "Bob status: #{bob.status}"

puts "\n--- Specifications ---"
high_risk = Loan::Specifications::HighRisk.new
puts "Alice's $25k loan high risk? #{high_risk.satisfied_by?(loan)}"
big_loan = OpenStruct.new(principal: 100_000, rate: 15)
puts "Hypothetical $100k/15% loan high risk? #{high_risk.satisfied_by?(big_loan)}"

puts "\n--- Final state ---"
puts "Customers: #{Customer.count}"
puts "Accounts: #{Account.count}"
puts "Transfers: #{Transfer.count}"
puts "Loans: #{Loan.count}"

puts "\nBalances:"
Account.all.each do |acct|
  owner = Customer.find(acct.customer_id)
  puts "  #{owner.name} #{acct.account_type}: $#{"%.2f" % acct.balance} (#{acct.status})"
end

puts "\nEvent log:"
app.events.each_with_index do |event, i|
  puts "  #{i + 1}. #{event.class.name.split('::').last}"
end
