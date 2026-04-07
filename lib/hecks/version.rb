# = Hecks::VERSION
#
# Defines the current version of the Hecks gem itself. This is the
# *framework* version, separate from individual domain versions managed
# by {Hecks::Versioner} (which uses CalVer: YYYY.MM.DD.N).
#
# Used by the gemspec for gem packaging and by the CLI for +hecks --version+
# output.
#
# @example
#   Hecks::VERSION  # => "0.1.0"
#
module Hecks
  VERSION = "2026.03.31.13"
end
