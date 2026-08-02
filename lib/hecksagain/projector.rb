module Hecksagain
  # Projections of a booted registry for other tools to read — the IR
  # exporter the bin/ir* scripts and the Rust conformance suite consume.
  module Projector
  end
end

require_relative "projector/exporter"
