# A transfer sent beyond the bank, where a recall is an instruction and a return is the external network's outcome.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class ExternalTransfer < Hecks::Rails::Model
  aggregate "Banking.ExternalTransfer"
end
