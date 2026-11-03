# frozen_string_literal: true

module Hecks
  module Adapters
    # How big a push is, against the QualityControl world's `push_nudge` setting: `commits:` and
    # `hours:` for when a push is due, and `urgent_commits:` for when it is urgent. It only says so
    # in a line; a push of any size is never refused.
    module PushSize
      # The world verb that carries the thresholds.
      VERB = "push_nudge"

      # The thresholds when the world declares none.
      DEFAULTS = { commits: 15, hours: 6, urgent_commits: 40 }.freeze

      # The word a Work item's title opens with when the push is past `urgent_commits`.
      URGENT = "URGENT"

      module_function

      # @param registry [Runtime::Registry, nil]
      # @return [Hash{Symbol => Integer, Float}] `commits:`, `hours:` and `urgent_commits:`
      def thresholds(registry)
        declared = registry&.world("QualityControl")&.for_verb(VERB) || {}
        merged = DEFAULTS.merge(declared.slice(*DEFAULTS.keys))
        { commits: Integer(merged[:commits]), hours: Float(merged[:hours]),
          urgent_commits: Integer(merged[:urgent_commits]) }
      end

      # @param ahead [Integer] the unpushed commits
      # @param limits [Hash] see {thresholds}
      # @return [Symbol] `:urgent`, `:over` or `:within`
      def size_class(ahead, limits)
        return :urgent if ahead > limits[:urgent_commits]

        ahead > limits[:commits] ? :over : :within
      end

      # @return [String] the sentence past the threshold, "" within it
      def sentence(ahead, limits)
        kind = size_class(ahead, limits)
        return "" if kind == :within

        "#{"#{URGENT} " if kind == :urgent}PUSH NOW: #{ahead} commits is over the #{limits[:commits]} you set " \
          "(urgent at #{limits[:urgent_commits]})"
      end

      # @return [String] the `push-due` Work item's title, naming the size class past the threshold
      def title(base, ahead, limits)
        case size_class(ahead, limits)
        when :urgent then "#{URGENT}: #{base}, #{ahead} commits"
        when :over then "#{base}, #{ahead} commits"
        else base
        end
      end
    end
  end
end
