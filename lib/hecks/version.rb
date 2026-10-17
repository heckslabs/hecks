module Hecks
  # Read directly by the gemspec, so this file must never require the
  # rest of the gem (its dependencies aren't resolved yet at that point).
  VERSION = "3.14.0".freeze # rust/host/HECKS_RELEASE names the same release
end
