# Hecks::Features
#
# Vertical slice architecture. Extracts vertical slices from domain
# reactive chains, validates slice boundaries, and generates diagrams.
#
require_relative "features/slice_step"
require_relative "features/vertical_slice"
require_relative "features/slice_extractor"
require_relative "features/leaky_slice_detection"
require_relative "features/slice_diagram"
require_relative "features/domain_mixin"

Hecks::DomainModel::Structure::Domain.include(Hecks::Features::DomainMixin)

# Backward compat
HecksFeatures = Hecks::Features unless defined?(HecksFeatures)
