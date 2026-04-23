# bin/specialize — single entry point for every i51 Futamura specializer.
#
# Replaces the three Phase A/B per-target scripts:
#   bin/specialize-validator
#   bin/specialize-validator-warnings
#   bin/specialize-dump
#
# Usage:
#   bin/specialize <target>                     # stdout
#   bin/specialize <target> --output PATH
#   bin/specialize <target> --diff
#   bin/specialize --list                       # list known targets
#
# Target names match SpecializerTarget.name in specializer.fixtures
# and the :specialize_<target> shell adapter names in
# specializer.hecksagon.
