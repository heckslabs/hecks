# The KYC check a newly registered customer clears before an account exists for them — screened once, and if it does not clear there is nothing to undo, because nothing was ever opened.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class OnboardingCase < Hecks::Rails::Model
  aggregate "Banking.OnboardingCase"
end
