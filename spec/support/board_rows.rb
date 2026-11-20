# frozen_string_literal: true

require "hecks"

# Builds a row as a value object of the PipelineBoard bluebook, the way the runtime builds an
# adapter's answer, so a spec can say an adapter's own rows are the shape the bluebook declares.
module BoardRows
  BOARD = File.expand_path("../../lib/hecks/pipeline_board", __dir__)

  # @return [Hecks::Bluebook::Aggregate] the PipelineBoard aggregate, described once
  def self.aggregate
    @aggregate ||= Hecks.describe(BOARD).registry.bluebooks.fetch("PipelineBoard").aggregates
                        .find { |candidate| candidate.hecks_name == "PipelineBoard" }
  end

  # @param name [String] a value object of the aggregate, such as `"Reading"`
  # @param row [Hash] one row an adapter answered
  # @return [Hash] the row as the built value object's fields
  # @raise [Hecks::Runtime::TypeMismatch, Hecks::Runtime::InvariantViolation,
  #   Hecks::Runtime::UnknownArgument] when the row is not that shape
  def built(name, row)
    aggregate = BoardRows.aggregate
    Hecks::Runtime::Value.build(Hecks::Runtime::Value.value_object_for(aggregate, name), row, aggregate).to_h
  end
end
