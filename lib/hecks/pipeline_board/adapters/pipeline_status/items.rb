# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The status's Work items and blocked runs, shaped from the cycles, the open Work items and
      # the sessions the board already read: each started item with its open stage and minutes in
      # it, and each blocked session with its question's first line and kind.
      module StatusItems
        # The text up to its first line break.
        FIRST_LINE = /\A[^\n]*/

        module_function

        # @param cycles [Array<Hash>] cycles as {Cycles.build} laid them (newest first)
        # @param work [Array<Hash>] the open `WorkLine` rows
        # @param sessions [Array<Hash>] the `SessionLine` rows
        # @return [Array<Hash>] one `StatusItem` per cycle open past its queue
        def items(cycles, work, sessions)
          started = cycles.reject { |cycle| cycle[:open].nil? || cycle[:open] == "queue" }
          started.map { |cycle| item(cycle, found(work, :slug, cycle[:work]), found(sessions, :work_item, cycle[:work])) }
        end

        # @return [Hash] the first row whose `key` is `value`, empty when none is
        def found(rows, key, value) = Array(rows).find { |row| row[key] == value } || {}

        def item(cycle, line, session)
          open = cycle[:stages].find { |entry| entry[:open] }
          { work: cycle[:work].to_s, stage: cycle[:open].to_s, minutes: open[:seconds] / 60,
            session_state: session[:status].to_s }.merge(described(line))
        end

        # @return [Hash] the title, epic, tier and priority of a `WorkLine`
        def described(line)
          { title: line[:title].to_s, epic: line[:epic].to_s, tier: line[:category].to_s, priority: line[:priority].to_s }
        end

        # @return [Array<Hash>] one `StatusBlock` per blocked session
        def blocked(sessions)
          Array(sessions).select { |session| session[:status] == "blocked" }.map { |session| block(session) }
        end

        def block(session)
          { run: session[:run].to_s, minutes: session[:idle_seconds].to_i / 60,
            first_line: first_line(session[:detail]), kind: session[:question_kind].to_s }
        end

        # @return [String] the text up to its first line break
        def first_line(text) = text.to_s[FIRST_LINE].strip
      end
    end
  end
end
