# The Statement aggregate of the Banking chapter, whose shape, rules and
# verbs the chapter declares. Presentation methods may be added here; a validation, callback
# or association may not (HecksRails/ThinModel).
class Statement < Hecks::Rails::Model
  aggregate "Banking.Statement"
end
