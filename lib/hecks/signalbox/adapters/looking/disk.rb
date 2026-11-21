# frozen_string_literal: true

module Hecks
  module Adapters
    class Looking
      # What the beat's look reads of the disk: its free space and size, and the steps macOS's
      # newest daily "disk writes" report counted for ruby, git, rustc and postgres. It returns the
      # report's facts as they stand and reckons no megabytes: the bluebook does.
      class Disk
        # Where macOS keeps its daily reports.
        REPORTS = "/Library/Logs/DiagnosticReports"
        # The processes the report is read for.
        PROCESSES = %w[ruby git rustc postgres].freeze
        # The day the report's window ended.
        END_DAY = /^End time:\s+(\d{4}-\d{2}-\d{2})/
        # The size of a step, in megabytes.
        STEP_SIZE = %r{\(([\d.]+) MB/step\)}

        # @param reports [String] the directory holding the `disk writes_*.diag` reports
        # @param root [String] the path whose disk is read
        def initialize(reports: REPORTS, root: "/")
          @reports = reports
          @root = root
        end

        # @return [Hash] `disk_free:` and `disk_total:` in megabytes, and the report's
        #   `writes_day:`, `step_hundredths:` and `<process>_steps:`, each nought or `none` when
        #   it cannot be read
        def facts = space.merge(writes)

        private

        def space
          row = df_row
          { disk_total: row[1].to_i / 1024, disk_free: row[3].to_i / 1024 }
        rescue SystemCallError
          { disk_total: 0, disk_free: 0 }
        end

        # The last line of `df -Pk`: device, blocks, used, available.
        def df_row
          out = IO.popen(["df", "-Pk", @root], err: File::NULL, &:read).to_s
          last_line(out).split
        end

        def last_line(text) = text.lines.last.to_s

        def writes
          text = report_text
          { writes_day:      text[END_DAY, 1] || "none",
            step_hundredths: step_hundredths(text) }.merge(steps(text))
        end

        def step_hundredths(text) = (text[STEP_SIZE, 1].to_f * 100).round

        # The newest report's text, empty when none is kept or it cannot be read.
        def report_text
          report = Dir[File.join(@reports, "disk writes_*.diag")].max
          report ? File.read(report) : ""
        rescue SystemCallError
          ""
        end

        def process_steps(name) = /^Powerstats for:\s+#{name}\n(?:.*\n){0,8}?Num samples:\s+(\d+)/

        def steps(text)
          PROCESSES.to_h do |name|
            [:"#{name}_steps", text[process_steps(name), 1].to_i]
          end
        end
      end
    end
  end
end
