module Hecksagain
  # Projections of a booted registry for other tools to read. The live
  # consumer is the translation-edge digest (translation/audit): an edge's
  # parsed content is serialized here so a compute approval can be bound to
  # exactly what a human reviewed.
  module Projector
  end
end

require_relative "projector/exporter"
