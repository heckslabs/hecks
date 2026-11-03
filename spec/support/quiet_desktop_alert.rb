# frozen_string_literal: true

require "hecks/hecks/adapters/desktop_alert"

# Keeps every spec from showing a desktop alert on the machine running it.
#
# A push and a red flag both ask the `Alerts` port, whose adapter runs `terminal-notifier` or
# `osascript`; a spec that walks either chain would otherwise pop an alert on the owner's screen
# and, on a machine with no notifier, record the ask as refused. While a spec runs the adapter's
# shell answers every program at once, and `shown` lists the commands it would have run, so a spec
# can read the alert's words.
module QuietDesktopAlert
  # A result every program ends with: status zero and nothing said.
  OK = Hecks::Adapters::Shell::Result.new("", "", Struct.new(:success?, :exitstatus).new(true, 0)).freeze

  # @return [Array<Array<String>>] the commands the adapter asked to run, oldest first
  def self.shown = (@shown ||= [])

  # Forgets the commands seen so far.
  def self.reset! = shown.clear

  # The shell the adapter is handed: it records and answers, and runs nothing.
  class Shell
    # @param command [Array<String>] the program and its arguments
    # @return [Hecks::Adapters::Shell::Result] a result that ended well
    def capture(*command, **)
      QuietDesktopAlert.shown << command
      OK
    end
  end

  # Prepended to the adapter, so the shell is swapped before any alert is shown. It names the same
  # keywords as the adapter, since the registry reads the constructor's parameters to decide what
  # to hand it.
  module Quiet
    def initialize(aggregate: nil, settings: {}, root: nil)
      super
      @shell = Shell.new
    end
  end
end

Hecks::Adapters::DesktopAlert.prepend(QuietDesktopAlert::Quiet)
