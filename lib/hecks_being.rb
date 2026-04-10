# HecksBeing
#
# Winter's living body. Boots all .bluebook files in hecks_being/winter/
# as always-alive domain runtimes, wired together by nerves
# (cross-domain event subscriptions).
#
#   winter = HecksBeing.boot
#   winter.graft("ImmuneSystem")
#   winter.pulse
#
require "hecks_being/organism"
require "hecks_being/organ_loader"
require "hecks_being/nerve_wirer"

module HecksBeing
  # @return [String] path to hecks_being/winter/
  def self.winter_dir
    File.join(ENV.fetch("HECKS_HOME", File.expand_path("../..", __dir__)), "hecks_being", "winter")
  end

  # @return [String] path to hecks_conception/nursery/
  def self.nursery_dir
    File.join(ENV.fetch("HECKS_HOME", File.expand_path("../..", __dir__)), "hecks_conception", "nursery")
  end

  # Boot Winter as a living organism.
  #
  # @return [Organism] Winter, alive
  def self.boot
    Organism.boot(winter_dir)
  end
end
