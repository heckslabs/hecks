# A balance belonging to one customer, and the ledger that explains how it got there.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class Account < Hecks::Rails::Model
  aggregate "Banking.Account"
end
