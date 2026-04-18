# HecksBeing
#
# Miette's living body. Boots her core organs (everything in
# hecks_conception/aggregates/ and hecks_conception/catalog/) as
# always-alive domain runtimes, wired together by nerves
# (cross-domain event subscriptions). Nursery and capabilities are
# grafted on demand, not booted automatically.
#
#   miette = HecksBeing.boot
#   miette.graft("ImmuneSystem")
#   miette.pulse
#
require "hecks_being/organism"
require "hecks_being/organ_loader"
require "hecks_being/nerve_wirer"

module HecksBeing
  # @return [String] path to hecks_conception/ — Miette's body
  def self.miette_dir
    File.join(ENV.fetch("HECKS_HOME", File.expand_path("../..", __dir__)), "hecks_conception")
  end

  # @return [String] path to hecks_conception/nursery/
  def self.nursery_dir
    File.join(ENV.fetch("HECKS_HOME", File.expand_path("../..", __dir__)), "hecks_conception", "nursery")
  end

  # Boot Miette as a living organism.
  #
  # @return [Organism] Miette, alive
  def self.boot
    Organism.boot(miette_dir)
  end
end
