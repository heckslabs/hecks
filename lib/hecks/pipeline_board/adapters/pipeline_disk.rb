# frozen_string_literal: true

require_relative "probe"

module Hecks
  module Adapters
    # The `Disk` reader: how much room the volume holding the checkout has left. It runs `df` and
    # reads its one volume line; it decides nothing, and writes nothing.
    class PipelineDisk
      KILOBYTES_PER_GIGABYTE = 1_048_576.0

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `df:` a callable taking the path and answering `df -Pk`'s output
      # @param root [String, nil] the checkout whose volume is read
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @df = settings[:df] || ->(path) { PipelineBoard::Probe.run("df", "-Pk", path) }
      end

      # @return [Hash{Symbol => Numeric}] `free_gb`, `total_gb` and `used_percent` of the volume
      # @raise [PipelineBoard::Unavailable] when `df` prints no volume line
      def free
        fields = volume_line.split
        raise PipelineBoard::Unavailable, "df printed no volume line for #{@root}" if fields.size < 5

        blocks, available = fields.values_at(1, 3).map { |kilobytes| Integer(kilobytes) }
        { free_gb: gigabytes(available), total_gb: gigabytes(blocks),
          used_percent: ((1 - (available.to_f / blocks)) * 100).round }
      end

      private

      # The volume's own line: `df -P` prints a header first.
      def volume_line
        output = @df.call(@root)
        output.lines.fetch(1, "")
      end

      def gigabytes(kilobytes) = (kilobytes / KILOBYTES_PER_GIGABYTE).round(1)
    end
  end
end
