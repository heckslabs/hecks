# Hecks::Features
#
# Vertical slice architecture. Extracts vertical slices from domain
# reactive chains, validates slice boundaries, and generates diagrams.
#
# Implementation files loaded from the FeaturesParagraph chapter definition.
# Uses narrow base_dir to avoid parent-child filter excluding these files.
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::FeaturesParagraph,
  base_dir: File.expand_path("features", __dir__)
)

Hecks::DomainModel::Structure::Domain.include(Hecks::Features::DomainMixin)

# Backward compat
HecksFeatures = Hecks::Features unless defined?(HecksFeatures)
