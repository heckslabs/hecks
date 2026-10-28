require_relative "agent"
require_relative "check"
require_relative "layout"
require_relative "session"

module Hecks
  module Composer
    # Carries one request from the author to the agent and back, on the hecksagon side: records it
    # in the draft's conversation, has the prompt classified, asks the agent to change the
    # workspace's files, judges what it left, asks once more when the check refused the result, and
    # records the agent's reply and the verdict.
    #
    # The agent edits the workspace on disk, so the files it changes are read before and after to
    # show the author what moved.
    class Assistant
      # How many times the agent may be asked about one request: the request, then a repair.
      ROUNDS = 2

      QUESTION_NOTE = "That reads as a question, so nothing was edited.".freeze

      # @param workspace [String] the domain directory the agent edits
      # @param agents [Runtime::Registry] a registry holding the `composer_agent` port and one
      #   adapter
      # @param session [Session] the editor's in-memory draft bookkeeping
      def initialize(workspace:, agents:, session:)
        @workspace = workspace
        @agents = agents
        @session = session
      end

      # @param prompt [String] what the author asked for
      # @return [Hash] `intent`, `note` (the agent's one-line account), `rounds` (how many times it
      #   was asked), `changed` (`{path => {before:, after:}}` for each file that differs), `check`
      #   (the whole check on what is now on disk) and `layout` (the panels to open, see {Layout})
      def ask(prompt)
        slug = File.basename(@workspace)
        before = snapshot
        open_draft(slug, before)
        @session.ask(slug: slug, said: prompt)
        intent = classify(prompt)
        note, rounds = edit(intent, prompt)
        outcome(slug, intent, note, rounds, before)
      end

      private

      def open_draft(slug, files)
        declaration = Parse.bluebooks(@workspace).keys.first || "Workspace"
        @session.open(slug: slug, bluebook_name: declaration, text: files.values.first.to_s)
      end

      # The prompt's intent; a classifier that cannot answer leaves it an edit.
      def classify(prompt)
        Agent.classify(@agents, prompt: prompt)
      rescue Agent::Unavailable
        "edit"
      end

      def edit(intent, prompt)
        return [QUESTION_NOTE, 0] if intent == "question"

        note = ask_agent(intent, prompt)
        refusal = Check.call(dir: @workspace)[:diagnostic]
        return [note, 1] unless refusal

        [ask_agent(intent, repair(prompt, refusal)), ROUNDS]
      end

      def ask_agent(intent, prompt)
        return Agent.wire(@agents, prompt: prompt, dir: @workspace) if intent == "wire"

        Agent.draft(@agents, prompt: prompt, dir: @workspace)
      end

      def repair(prompt, refusal)
        where = refusal[:line] ? "#{refusal[:file]} line #{refusal[:line]}: " : ""
        expected = refusal[:expected].to_a.empty? ? "" : " (expected one of: #{refusal[:expected].join(", ")})"
        "#{prompt}\n\nYour last edit was refused by the check, so fix it: #{where}#{refusal[:message]}#{expected}"
      end

      def outcome(slug, intent, note, rounds, before)
        after = snapshot
        check = Check.call(dir: @workspace)
        @session.answer(slug: slug, said: note, text: after.values.first.to_s)
        @session.judge(slug: slug, diagnostic: check[:diagnostic])
        moved = changed(before, after)
        record(moved)
        { intent: intent, note: note, rounds: rounds, changed: moved, check: check,
          layout: Layout.propose(intent: intent, check: check, changed: moved) }
      end

      # Keeps each file the agent changed in the timeline, as a save would.
      def record(moved)
        moved.each { |path, text| @session.record(path: path, text: text[:after]) if text[:after] }
      end

      def changed(before, after)
        (before.keys | after.keys).sort.each_with_object({}) do |path, moved|
          next if before[path] == after[path]

          moved[path] = { before: before[path], after: after[path] }
        end
      end

      def snapshot
        Workspace.files(@workspace).to_h { |path| [path, File.read(File.join(@workspace, path))] }
      end
    end
  end
end
