# A card authorisation that either settles, is voided before settlement, or becomes a post-settlement dispute.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class CardPayment < Hecks::Rails::Model
  aggregate "Banking.CardPayment"
end
