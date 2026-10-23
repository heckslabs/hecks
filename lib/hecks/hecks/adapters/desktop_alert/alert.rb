# frozen_string_literal: true

module Hecks
  module Adapters
    class DesktopAlert
      # One alert, and the program that shows it on this machine: `terminal-notifier` where it is
      # installed, since clicking its alert opens the link; else `osascript` on macOS, whose alert
      # opens Script Editor when clicked; else `notify-send`.
      #
      # @!attribute [r] title
      #   @return [String] the alert's first line
      # @!attribute [r] subtitle
      #   @return [String] the line beneath it
      # @!attribute [r] body
      #   @return [String] the rest
      # @!attribute [r] link
      #   @return [String, nil] what clicking the alert opens
      Alert = Struct.new(:title, :subtitle, :body, :link, keyword_init: true) do
        # Shows the alert with the first program this machine has.
        #
        # @param shell [Shell] the adapter the program runs through
        # @return [Shell::Result] how the last program tried ended; 127 when none is installed
        def show(shell)
          shown = shell.capture(*notifier)
          return shown unless shown.status.exitstatus == 127

          shell.capture(*fallback)
        end

        private

        def notifier
          ["terminal-notifier", "-title", title, "-subtitle", subtitle, "-message", body.empty? ? subtitle : body,
           "-group", title, "-sound", "Glass", *(["-open", link] if link)]
        end

        def fallback
          return ["notify-send", title, "#{subtitle}\n#{body}"] unless RUBY_PLATFORM.include?("darwin")

          ["osascript", "-e", "display notification #{quoted(body)} with title #{quoted(title)} " \
                              "subtitle #{quoted(subtitle)} sound name \"Glass\""]
        end

        # An AppleScript string literal.
        def quoted(text) = "\"#{text.gsub(/[\\"]/) { |char| "\\#{char}" }}\""
      end
    end
  end
end
