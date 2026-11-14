module Hecks
  module Bluebook
    module ModelCheck
      # The checks over a timeout row that names a lifecycle state: the state exists, the row's
      # opening event is one that enters it, and its closing events cover every way out.
      module TimeoutRowChecks
        # @param passage [Passage] the aggregate's lifecycle, read for its ways in and out
        # @param states [Array<String>] every state the lifecycle declares
        # @param row [Hash{Symbol => Object}] a timeout row: `kind`, `aggregate`, `state`, `opens`,
        #   `closes` and `ends`, the last two comma separated
        # @return [Array<Finding>] what the row gets wrong about the state it times
        def timeout_row_findings(passage, states, row)
          state = row[:state].to_s
          return [unknown_timeout_state(row)] unless states.include?(state)

          [opens_elsewhere_finding(passage, row, state), open_exit_finding(passage, row, state)].compact
        end

        # @param row [Hash{Symbol => Object}] a timeout row
        # @return [Finding] the error for a row naming a state its aggregate's lifecycle lacks
        def unknown_timeout_state(row)
          row_finding(:timeout_unknown_state, row,
                      "times #{row[:state].to_s.inspect}, which is no lifecycle state of #{row[:aggregate]}")
        end

        # @return [Finding, nil] the error for a row whose opening event does not enter its state
        def opens_elsewhere_finding(passage, row, state)
          entering = passage.entering_events(state)
          return if entering.include?(row[:opens].to_s)

          row_finding(:timeout_opens_elsewhere, row,
                      "opens on #{row[:opens].to_s.inspect}, but #{state.inspect} is entered by " \
                      "#{entering.inspect}: the clock would start somewhere else")
        end

        # @return [Finding, nil] the error for a row whose closing events miss a way out
        def open_exit_finding(passage, row, state)
          missed = passage.leaving_events(state) - closing_events(row)
          return if missed.empty?

          row_finding(:timeout_open_exit, row,
                      "#{state.inspect} is also left by #{missed.inspect}, which the row's closes do not " \
                      "name: a record that left would still be filed as stalled")
        end

        # @param row [Hash{Symbol => Object}] a timeout row
        # @return [Array<String>] the events that close the row, its run-ending events included
        def closing_events(row) = [row[:closes], row[:ends]].flat_map { |list| list.to_s.split(",").map(&:strip) }

        # @return [Finding] an error about one timeout row, named by its kind
        def row_finding(kind, row, message)
          Finding.new(kind: kind, severity: :error, subject: row.fetch(:kind, row[:aggregate]).to_s, message: message)
        end
      end
    end
  end
end
