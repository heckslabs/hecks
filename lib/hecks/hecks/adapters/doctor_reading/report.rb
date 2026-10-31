# frozen_string_literal: true

module Hecks
  module Adapters
    class DoctorReading
      # Formats the checks: one line each, the fix beneath any check that is not ok.
      module Report
        private

        def render(rows)
          lines = rows.map { |name, status, detail, fix| line(name, status, detail, fix) }
          (lines + ["status: #{worst(rows)}"]).join("\n")
        end

        def worst(rows)
          statuses = rows.map { |row| row[1] }
          statuses.max_by { |status| %i[ok warn fail].index(status) }
        end

        def line(name, status, detail, fix)
          head = format("%<state>-5s %<name>-16s %<detail>s", state: status.to_s.upcase, name: name, detail: detail)
          fix ? "#{head}\n      fix: #{fix}" : head
        end
      end
    end
  end
end
