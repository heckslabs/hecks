# A steel box in the vault, held under one customer's name and opened only against the branch and number stamped on its face.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class SafeDepositBox < Hecks::Rails::Model
  aggregate "Banking.SafeDepositBox"
end
