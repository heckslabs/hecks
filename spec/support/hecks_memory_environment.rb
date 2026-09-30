# Keeps every spec that boots the Hecks domain (lib/hecks/hecks) off a database.
#
# The domain is bound to PostgresEra in hecks.world; its environments/memory.world overlay
# swaps it to Memory. `Hecks.boot` reads `HECKS_ENVIRONMENT`, so setting it once here covers
# every boot a spec makes, directly or through an adapter, without touching each spec.
# A spec that needs the real journal boots a child process with the variable unset.
module HecksMemoryEnvironment
  NAME = "memory".freeze
  VARIABLE = "HECKS_ENVIRONMENT".freeze

  # Selects the Memory overlay unless the run already chose an environment.
  #
  # @return [String] the environment now selected
  def self.select!
    ENV[VARIABLE] = NAME if ENV[VARIABLE].to_s.empty?
    ENV.fetch(VARIABLE)
  end
end

HecksMemoryEnvironment.select!
