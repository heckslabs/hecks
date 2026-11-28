# frozen_string_literal: true

module Hecks
  module Adapters
    class CrewUsage
      # The reading of one window as the lines the `Reading` query returns.
      class Text
        # @param day [String] the sprint day
        # @param start [Time] when the window opens
        # @param calc [Calc] the window's figures
        # @param transcripts [Transcripts] the reader, for what it skipped
        def initialize(day, start, calc, transcripts)
          @day = day
          @start = start
          @calc = calc
          @transcripts = transcripts
        end

        # @return [String] one `name: value` line per figure
        def to_s = lines.join("\n")

        private

        def lines
          ["baseline #{@day} from #{@start.utc.iso8601} for #{Calc::WINDOW_MINUTES} minutes",
           "tokens_per_minute: #{@calc.tokens_per_minute.round(1)}", "items_per_hour: #{@calc.items_per_hour.round(2)}",
           "cache_hit_rate: #{@calc.cache_hit_rate.round(4)}", "tokens_per_item: #{per_item}",
           "by_role: #{roles}", "skipped_lines: #{@transcripts.skipped}", "capped_files: #{@transcripts.capped}"]
        end

        def per_item = @calc.tokens_per_item&.round(1) || "unknown"

        def roles = @calc.by_role.map { |role, figures| entry(role, figures) }.join(";")

        def entry(role, figures)
          "#{role}=#{figures[:tokens_per_minute].round(1)}/#{figures[:cache_hit_rate].round(4)}"
        end
      end
    end
  end
end
