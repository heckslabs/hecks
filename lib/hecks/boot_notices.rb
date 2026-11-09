# frozen_string_literal: true

module Hecks
  # The lines the runtime writes while it boots, which are never the reason a command failed, and
  # the one place that tells them from a command's own words.
  #
  # A refusal built from captured output would open with whichever line came first, so a run
  # that did nothing read as "process manager X has no save_saga" when the real cause was a
  # missing `confirm`. `compose` puts the command's own words first and the notices after a
  # divider, so nothing is lost and the first line is the cause. The notices still print once to
  # stderr as the process boots; this changes how a refusal is worded, not what is printed.
  module BootNotices
    # The notices, by name. The last matches any other `[hecks]` warning; it is listed last so
    # the named ones report themselves first.
    PATTERNS = {
      saga_durability:  /\A\[hecks\] .*has no save_saga/,
      outbox_claimed:   %r{\A\[hecks\] outbox row .* was claimed before the last crash/restart},
      worktree_overlay: /\Ahecks: this worktree lacks /,
      runtime_warning:  /\A\[hecks\] /
    }.freeze

    # The line between a refusal's cause and the notices that came with it.
    DIVIDER = "-- boot notices --"

    module_function

    # @param line [String] one line of captured output
    # @return [Boolean] whether it is a boot notice
    def notice?(line) = !name_of(line).nil?

    # @param line [String] one line of captured output
    # @return [Symbol, nil] the name of the notice it is, nil when it is the command's own
    def name_of(line) = PATTERNS.find { |_, pattern| pattern.match?(line.to_s) }&.first

    # Splits captured output into the command's own lines and the notices, each in order.
    #
    # @param text [String] captured output, possibly already composed
    # @return [Array(String, String)] the cause and the notices, each stripped
    def split(text)
      notices, cause = lines_of(text).partition { |line| notice?(line) }
      [cause.join("\n").strip, notices.join("\n").strip]
    end

    # @param text [String] captured output, possibly already composed
    # @return [Array<String>] its lines without the divider
    def lines_of(text) = text.to_s.each_line(chomp: true).reject { |line| line.strip == DIVIDER }

    # The refusal text: the command's own words, then the divider and the notices.
    #
    # @param text [String] captured output
    # @return [String] the cause alone when there are no notices, the notices alone when there is
    #   no cause, else the cause, the divider and the notices
    def compose(text)
      cause, notices = split(text)
      return cause if notices.empty?
      return notices if cause.empty?

      [cause, DIVIDER, notices].join("\n")
    end

    # The cause a person reads on one line of stderr: the command's own words, else the notices
    # when it said nothing else.
    #
    # @param text [String] captured output, composed or not
    # @return [String] the cause, or the notices when there is none
    def cause(text)
      cause, notices = split(text)
      cause.empty? ? notices : cause
    end
  end
end
