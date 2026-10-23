module Hecks
  # Read directly by the gemspec, so this file must never require the
  # rest of the gem (its dependencies aren't resolved yet at that point).
  VERSION = "4.0.0".freeze # rust/host/HECKS_RELEASE and @hecks/client name the same release
end
