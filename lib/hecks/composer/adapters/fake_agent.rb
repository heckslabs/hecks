require_relative "../agent"

module Hecks
  module Adapters
    # A scripted `composer_agent`, for specs and for trying the editor with no model behind it.
    # Each ask is recorded; `draft` and `wire` run a script that may rewrite the workspace's files,
    # so a test sees the same thing the real agent leaves behind.
    module FakeAgent
      class << self
        # @return [Array<Hash>] every ask, as `{ask:, prompt:, dir:}` in the order made
        def calls = @calls ||= []

        # @return [#call, nil] takes `(prompt, dir)` and edits files under `dir`; may return a note
        attr_accessor :edit

        # @return [#call, nil] takes `prompt` and answers an intent
        attr_accessor :intent

        # Forgets the calls and both scripts.
        # @return [void]
        def reset!
          @calls = []
          @edit = nil
          @intent = nil
        end
      end

      module_function

      # @param prompt [String] what the author asked for
      # @param dir [String] the workspace directory
      # @return [Hash] `"note"` what the script reported
      def draft(prompt:, dir:) = edited(:draft, prompt, dir)

      # @param prompt [String] what the author asked for
      # @param dir [String] the workspace directory
      # @return [Hash] `"note"` what the script reported
      def wire(prompt:, dir:) = edited(:wire, prompt, dir)

      # @param prompt [String] what the author typed
      # @return [Hash] `"intent"` what the script answered, `"edit"` without one
      def classify(prompt:)
        FakeAgent.calls << { ask: :classify, prompt: prompt, dir: nil }
        { "intent" => FakeAgent.intent ? FakeAgent.intent.call(prompt) : "edit" }
      end

      # @api private
      def edited(ask, prompt, dir)
        FakeAgent.calls << { ask: ask, prompt: prompt, dir: dir }
        note = FakeAgent.edit&.call(prompt, dir)
        { "note" => note.is_a?(String) ? note : "changed nothing" }
      end
    end
  end
end
