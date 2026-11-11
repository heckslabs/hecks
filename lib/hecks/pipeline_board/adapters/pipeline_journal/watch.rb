# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Follows the journal (`events.jsonl`, the runtime's event tap) as it grows and hands each new
      # line to a block, so the board learns of an event when it is written and never by asking on a
      # clock. The default source is `tail -F`, a blocking read that costs nothing while the
      # file is quiet and follows the file across the tap's rotations. A line that is not JSON is
      # dropped.
      class Watch
        # @param path [String] the journal's path
        # @param source [#call, nil] answers an IO-like object whose `gets` blocks for the next line
        #   and answers nil at the end; stands in for `tail` (a spec's fake journal)
        def initialize(path:, source: nil)
          @source = source || -> { IO.popen(["tail", "-n", first_line(path), "-F", path.to_s], err: File::NULL) }
        end

        # Reads lines on a thread until the source ends or {#stop}.
        #
        # @yieldparam row [Hash] `seq` (the tap's own number for the line), `aggregate` (the
        #   aggregate of the event; nil on a reaction line) and `kind`
        # @return [Watch] self
        def start(&on_row)
          @io = @source.call
          @thread = Thread.new { follow(&on_row) }
          self
        end

        # Stops reading and releases the source; a followed process (`tail`) is ended first, since
        # closing its pipe would wait for it to exit and it exits only when the journal is written.
        def stop
          @thread&.kill
          Process.kill("TERM", @io.pid) if @io.respond_to?(:pid)
          @io.close if @io.respond_to?(:close) && !(@io.respond_to?(:closed?) && @io.closed?)
        rescue SystemCallError
          nil
        end

        private

        # `0` for a journal that exists, since only what is written from now on is news; `+1` for
        # one that does not yet, since every line of a journal that appears is new.
        def first_line(path) = File.exist?(path.to_s) ? "0" : "+1"

        def follow
          while (line = @io.gets)
            row = decode(line)
            yield row if row
          end
        end

        def decode(line)
          data = JSON.parse(line)
          { seq: data["seq"], aggregate: data["aggregate"], kind: data["kind"] } if data.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
