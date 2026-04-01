#!/usr/bin/env ruby
# Build a banking domain live using the Hecks Session API.
# This is exactly what you'd type in `hecks console`.

require_relative "../../lib/hecks"

session = Hecks.session("Banking")

# --- Customer ---

customer = session.aggregate("Customer")
customer.attr :name
customer.attr :email
customer.attr :status, default: "active"

customer.value_object("Address") do
  attribute :street, String
  attribute :city, String
  attribute :state, String
  attribute :zip, String
end

customer.attr :address, customer.list_of("Address")

customer.command("RegisterCustomer") do
  attribute :name, String
  attribute :email, String
end

customer.command("SuspendCustomer") do
  attribute :customer_id, String
end

customer.command("NotifyCustomer") do
  attribute :customer_id, String
  attribute :message, String
end

customer.validation :name, presence: true
customer.validation :email, presence: true

customer.scope :active, ->(all) { all.select { |c| c.status == "active" } }

customer.on_event("RegisteredCustomer") do |event|
  puts "Welcome email sent to #{event.email}"
end

# --- Account ---

account = session.aggregate("Account")
account.attr :customer_id, account.reference_to("Customer")
account.attr :balance, Float
account.attr :account_type  # checking, savings
account.attr :daily_limit, Float
account.attr :status, default: "open"

account.command("OpenAccount") do
  attribute :customer_id, String
  attribute :account_type, String
  attribute :daily_limit, Float
end

account.command("Deposit") do
  attribute :account_id, String
  attribute :amount, Float
end

account.command("Withdraw") do
  attribute :account_id, String
  attribute :amount, Float
end

account.command("FlagSuspiciousActivity") do
  attribute :account_id, String
  attribute :reason, String
end

account.command("CloseAccount") do
  attribute :account_id, String
end

account.validation :account_type, presence: true

account.query "ByCustomer" do |customer_id|
  where(customer_id: customer_id)
end

account.scope :open, ->(all) { all.select { |a| a.status == "open" } }
account.scope :checking, ->(all) { all.select { |a| a.account_type == "checking" } }

account.on_event("Deposited") do |event|
  puts "Deposit receipt for account #{event.account_id}: $#{event.amount}"
end

# Fraud check on large withdrawals
account.policy("FraudAlert") do
  on "Withdrew"
  trigger "FlagSuspiciousActivity"
end

# --- Transfer ---

transfer = session.aggregate("Transfer")
transfer.attr :from_account_id, transfer.reference_to("Account")
transfer.attr :to_account_id, transfer.reference_to("Account")
transfer.attr :amount, Float
transfer.attr :status, default: "pending"
transfer.attr :memo

transfer.command("InitiateTransfer") do
  attribute :from_account_id, String
  attribute :to_account_id, String
  attribute :amount, Float
  attribute :memo, String
end

transfer.command("CompleteTransfer") do
  attribute :transfer_id, String
end

transfer.command("RejectTransfer") do
  attribute :transfer_id, String
end

transfer.validation :amount, presence: true

transfer.query "HighValue" do
  where(amount: Hecks::Querying::Operators::Gte.new(1000.0))
end

transfer.scope :pending, ->(all) { all.select { |t| t.status == "pending" } }
transfer.scope :completed, ->(all) { all.select { |t| t.status == "completed" } }

transfer.on_event("CompletedTransfer") do |event|
  puts "Transfer #{event.transfer_id} completed — notify both parties"
end

# --- Loan ---

loan = session.aggregate("Loan")
loan.attr :customer_id, loan.reference_to("Customer")
loan.attr :account_id, loan.reference_to("Account")
loan.attr :principal, Float
loan.attr :rate, Float
loan.attr :term_months, Integer
loan.attr :status, default: "pending"
loan.attr :remaining_balance, Float

loan.value_object("PaymentScheduleEntry") do
  attribute :due_date, String
  attribute :principal_amount, Float
  attribute :interest_amount, Float
  attribute :total_amount, Float
end

loan.attr :payment_schedule, loan.list_of("PaymentScheduleEntry")

loan.value_object("Disbursement") do
  attribute :amount, Float
  attribute :disbursed_at, String
  attribute :method, String
end

loan.command("IssueLoan") do
  attribute :customer_id, String
  attribute :account_id, String
  attribute :principal, Float
  attribute :rate, Float
  attribute :term_months, Integer
end

loan.command("MakePayment") do
  attribute :loan_id, String
  attribute :amount, Float
end

loan.command("DefaultLoan") do
  attribute :loan_id, String
  attribute :reason, String
end

loan.command("RefinanceLoan") do
  attribute :loan_id, String
  attribute :new_rate, Float
  attribute :new_term_months, Integer
end

loan.validation :principal, presence: true
loan.validation :rate, presence: true

loan.invariant("rate must be between 0 and 100") do
  rate.nil? || (rate >= 0 && rate <= 100)
end

loan.query "ByCustomer" do |customer_id|
  where(customer_id: customer_id)
end

loan.query "Delinquent" do
  where(status: "defaulted")
end

loan.scope :active, ->(all) { all.select { |l| l.status == "active" } }
loan.scope :pending, ->(all) { all.select { |l| l.status == "pending" } }

# When a loan is issued, deposit the principal into the linked account
loan.policy("DisburseFunds") do
  on "IssuedLoan"
  trigger "Deposit"
end

# Suspend customer on default
loan.policy("SuspendOnDefault") do
  on "DefaultedLoan"
  trigger "SuspendCustomer"
end

loan.on_event("MadePayment") do |event|
  puts "Payment of $#{event.amount} received for loan #{event.loan_id}"
end

# --- Describe & Validate ---

puts ""
puts "=== Domain Overview ==="
session.describe

puts ""
puts "=== Validation ==="
session.validate

# --- Play Mode ---

puts ""
puts "=== Play Mode ==="
session.play!

puts ""
puts "--- Register a customer ---"
session.execute("RegisterCustomer", name: "Alice Johnson", email: "alice@example.com")

puts ""
puts "--- Open accounts ---"
session.execute("OpenAccount", customer_id: "cust-1", account_type: "checking", daily_limit: 5000.0)
session.execute("OpenAccount", customer_id: "cust-1", account_type: "savings", daily_limit: 10000.0)

puts ""
puts "--- Deposit ---"
session.execute("Deposit", account_id: "acct-1", amount: 1000.0)

puts ""
puts "--- Withdraw (triggers FraudAlert policy) ---"
session.execute("Withdraw", account_id: "acct-1", amount: 250.0)

puts ""
puts "--- Transfer between accounts ---"
session.execute("InitiateTransfer",
  from_account_id: "acct-1",
  to_account_id: "acct-2",
  amount: 500.0,
  memo: "Monthly savings"
)
session.execute("CompleteTransfer", transfer_id: "xfer-1")

puts ""
puts "--- Issue a loan (triggers DisburseFunds -> Deposit) ---"
session.execute("IssueLoan",
  customer_id: "cust-1",
  account_id: "acct-1",
  principal: 25000.0,
  rate: 5.25,
  term_months: 60
)

puts ""
puts "--- Make a payment ---"
session.execute("MakePayment", loan_id: "loan-1", amount: 450.0)

puts ""
puts "--- Refinance ---"
session.execute("RefinanceLoan", loan_id: "loan-1", new_rate: 3.75, new_term_months: 48)

puts ""
puts "--- Event History ---"
session.history

puts ""
puts "--- Available Commands ---"
session.commands.each { |c| puts "  #{c}" }

# --- Instance methods on live objects ---

puts ""
puts "--- Instance Command Methods ---"
mod = Object.const_get("BankingDomain")
xfer = mod::Transfer.new(from_account_id: "acct-1", to_account_id: "acct-2", amount: 750.0, memo: "Rent")
puts "Transfer instance: from=#{xfer.from_account_id} to=#{xfer.to_account_id} amount=#{xfer.amount}"
event = xfer.initiate
puts "xfer.initiate -> #{event.class.name.split('::').last}"

puts ""
puts "--- Mutate and reset ---"
xfer.amount = 9999.0
puts "After mutation: amount=#{xfer.amount}"
xfer.reset!
puts "After reset!:   amount=#{xfer.amount}"

# --- Build & Save ---

puts ""
puts "=== Build Domain Gem ==="
session.define!
session.build

puts ""
puts "=== Save DSL ==="
session.save
