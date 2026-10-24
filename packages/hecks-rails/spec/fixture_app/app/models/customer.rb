# A person the bank holds a relationship with. Suspended rather than deleted — a bank forgets nothing.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class Customer < Hecks::Rails::Model
  aggregate "Banking.Customer"
end
