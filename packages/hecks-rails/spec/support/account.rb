# The fixture's skin over Ledger::Account.
class Account < Hecks::Rails::Model
  aggregate "Ledger.Account"
end
