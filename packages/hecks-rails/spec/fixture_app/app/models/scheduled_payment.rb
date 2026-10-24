# An instruction held for a future date, which may execute once or be cancelled before it does.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class ScheduledPayment < Hecks::Rails::Model
  aggregate "Banking.ScheduledPayment"
end
