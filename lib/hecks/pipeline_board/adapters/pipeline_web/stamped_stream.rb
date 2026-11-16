# frozen_string_literal: true

require "delegate"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's standard error with the time at the start of every line it writes, so a line in
      # `board.log` says when it happened. `warn`, `puts` and `print` all reach {#write}. Output of
      # child processes goes to the descriptor directly and is not stamped.
      class StampedStream < SimpleDelegator
        # Runs the block with `$stderr` stamped, and puts the stream back after it.
        # @yield the work to run
        # @return [Object] what the block answers
        def self.during
          install
          yield
        ensure
          restore
        end

        # Puts a stamped stream in place of `$stderr`; one already there is left as it is.
        # @return [void]
        def self.install
          $stderr = new($stderr) unless $stderr.is_a?(self)
        end

        # Puts the stream the stamped one wraps back in place of `$stderr`.
        # @return [void]
        def self.restore
          $stderr = $stderr.__getobj__ if $stderr.is_a?(self)
        end

        # @param inner [IO] the stream written to
        # @param clock [#call] answers the time a line is stamped with
        def initialize(inner, clock: -> { Time.now.utc })
          super(inner)
          @clock = clock
          @fresh = true
        end

        # @param parts [Array<#to_s>] what to write
        # @return [Integer] the bytes of the text given, without the stamps
        def write(*parts)
          text = parts.join
          return 0 if text.empty?

          __getobj__.write(stamped(text))
          @fresh = text.end_with?("\n")
          text.bytesize
        end

        # @param parts [Array<#to_s>] what to write, as `IO#print` takes it
        # @return [nil]
        def print(*parts)
          write(*parts)
          nil
        end

        # @param parts [Array<#to_s>] what to write, a line for each, as `IO#puts` takes it
        # @return [nil]
        def puts(*parts)
          lines = parts.flatten.map { |part| part.to_s.end_with?("\n") ? part.to_s : "#{part}\n" }
          write(lines.empty? ? "\n" : lines.join)
          nil
        end

        # @param part [#to_s] what to write
        # @return [StampedStream] self
        def <<(part)
          write(part)
          self
        end

        private

        def stamped(text)
          mark = "#{@clock.call.strftime("%Y-%m-%dT%H:%M:%SZ")} "
          first, *rest = text.lines
          [@fresh ? "#{mark}#{first}" : first, *rest.map { |line| "#{mark}#{line}" }].join
        end
      end
    end
  end
end
