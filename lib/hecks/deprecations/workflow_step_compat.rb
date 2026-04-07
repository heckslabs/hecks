# HecksDeprecations::WorkflowStepCompat
#
# Registers deprecated hash-style [] and to_h on CommandStep,
# BranchStep, and ScheduledStep.
#
#   step[:command]  # => warns, returns step.command
#

# CommandStep
HecksDeprecations.register(Hecks::DomainModel::Behavior::CommandStep, :[]) do |key|
  HecksDeprecations.warn_deprecated(self.class, "[]")
  case key
  when :command then command
  when :mapping then mapping
  end
end

HecksDeprecations.register(Hecks::DomainModel::Behavior::CommandStep, :to_h) do
  HecksDeprecations.warn_deprecated(self.class, "to_h")
  { command: command, mapping: mapping }
end

# BranchStep
HecksDeprecations.register(Hecks::DomainModel::Behavior::BranchStep, :[]) do |key|
  HecksDeprecations.warn_deprecated(self.class, "[]")
  case key
  when :branch then self
  when :spec then spec
  when :if_steps then if_steps
  when :else_steps then else_steps
  end
end

HecksDeprecations.register(Hecks::DomainModel::Behavior::BranchStep, :to_h) do
  HecksDeprecations.warn_deprecated(self.class, "to_h")
  { branch: { spec: spec, if_steps: if_steps, else_steps: else_steps } }
end

# ScheduledStep
HecksDeprecations.register(Hecks::DomainModel::Behavior::ScheduledStep, :[]) do |key|
  HecksDeprecations.warn_deprecated(self.class, "[]")
  send(key) if respond_to?(key)
end

HecksDeprecations.register(Hecks::DomainModel::Behavior::ScheduledStep, :to_h) do
  HecksDeprecations.warn_deprecated(self.class, "to_h")
  { name: name, find_aggregate: find_aggregate, find_spec: find_spec,
    find_query: find_query, trigger: trigger }
end
