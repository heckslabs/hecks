# A snapshot of one account's activity over one period, generated once and never revised.
#
# Its shape, rules and verbs are the Banking chapter's. Presentation methods may be
# added here; a validation, callback or association may not (HecksRails/ThinModel).
class Statement < Hecks::Rails::Model
  aggregate "Banking.Statement"
end
