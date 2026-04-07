# Hecks::Stats
#
# Domain and project statistics: aggregate counts, attribute counts,
# command/event/policy metrics.
#
module Hecks
  # Hecks::Stats
  #
  # Domain and project statistics: aggregate counts, attribute counts, command/event/policy metrics.
  #
  module Stats
    autoload :DomainStats,  "hecks/stats/domain_stats"
    autoload :ProjectStats, "hecks/stats/project_stats"
  end
end
