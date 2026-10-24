# A card issued against an account, and the cash taken with it.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class AtmCard < Hecks::Rails::Model
  aggregate "Banking.ATMCard"
end
