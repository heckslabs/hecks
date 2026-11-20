# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # Whether the last fill's report is stale, as the bluebook's `Fill age` rows say of its age,
      # and the words the page marks a stale one with. It reads a fill preview and decides nothing.
      module FillAge
        module_function

        # @param fill [Hash, nil] a {PipelineFill#preview}, or `{unknown: reason}`
        # @return [Boolean] whether the `Fill age` rows call its age stale; an unread fill and a
        #   report that states no time are not
        def stale?(fill)
          fill.is_a?(Hash) && Rules.verdict("Fill age", { age_minutes: fill[:age_minutes] }) == "stale"
        end

        # @param fill [Hash] a stale fill preview
        # @return [String] how old the report is, in words
        def note(fill) = "the last fill ran #{fill[:age_minutes]} minutes ago"

        # @param fill [Hash, nil] a fill preview, or `{unknown: reason}`
        # @return [Hash, nil] the preview with `stale` stated, so the page need not judge its age
        def marked(fill)
          fill.is_a?(Hash) && !fill.key?(:unknown) ? fill.merge(stale: stale?(fill)) : fill
        end

        # @param sections [Hash{Symbol => Hash}] the sections already showing an earlier answer
        # @param fill [Hash, nil] a fill preview, or `{unknown: reason}`
        # @return [Hash{Symbol => Hash}] the sections, the fill added when its report is stale and
        #   its read was not itself skipped
        def noted(sections, fill)
          return sections if sections.key?(:fill) || !stale?(fill)

          sections.merge(fill: { since: fill[:at], reason: note(fill) })
        end
      end
    end
  end
end
