# Money leaving one account for another. Two movements that must both happen, or neither.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class Transfer < Hecks::Rails::Model
  aggregate "Banking.Transfer"
end
