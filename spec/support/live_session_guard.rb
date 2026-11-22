# frozen_string_literal: true

require "tmpdir"
require "hecks/hecks/adapters/shell"

# Keeps every spec from starting or resuming a real background Claude session. A spec that boots
# the Hecks domain's real wiring can reach `AgentRun.Dispatch` through a policy chain (a drafted
# decision asks the architect), and the `claude --bg` it runs outlives the example: the session's
# run lives in the spec's Memory, so no ledger records it and it blocks idle for good. A `claude`
# with `--bg` is let through only when it is a stand-in under the temporary directory
# ("with a stand-in claude"); any other is refused by name before it runs, and the example fails
# even when the port's caller turns the refusal into a declined run.
module LiveSessionGuard
  # Raised when a spec reaches for a real `claude` session.
  class Violation < StandardError; end

  # The program asked for.
  COMMAND = "claude"

  # The flag that starts or resumes a session in the background.
  BACKGROUND = "--bg"

  # The word that lists sessions, which starts the real program as surely as `--bg` does.
  LISTING = "agents"

  @refused = []

  class << self
    # @return [Array<String>] the refusals since the last {.take}
    attr_reader :refused

    # @return [Array<String>] the refusals since the last call, cleared
    def take = @refused.slice!(0..)
  end

  module_function

  # @param command [Array<String>] the program, then its arguments
  # @param env [Hash{String => String, nil}] the variables the program is given
  # @return [String, nil] why the command is refused, or nil to let it run
  def refusal(command, env)
    program = program_of(command)
    return unless program && session_command?(command)

    found = located(program, env)
    return if found && temporary?(found)

    "a spec started a real #{COMMAND} session (#{found || program}); include the \"with a stand-in claude\" " \
      "context or stand in for the shell"
  end

  # @return [Boolean] whether the command starts, resumes or lists sessions
  def session_command?(command) = command.include?(BACKGROUND) || command.include?(LISTING)

  # @return [String, nil] the `claude` the command runs, past a `nice -n N` prefix
  def program_of(command)
    words = command.first == "nice" ? command.drop(3) : command
    words.first if File.basename(words.first.to_s) == COMMAND
  end

  # @return [String, nil] the real path of the program: as given, or the first on `PATH`
  def located(program, env)
    return File.realpath(program) if program.include?("/") && File.exist?(program)

    path = env.fetch("PATH", ENV.fetch("PATH", "")).to_s
    found = path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, program) }.find { |place| File.executable?(place) }
    found && File.realpath(found)
  end

  # @return [Boolean] whether the path lies under the temporary directory
  def temporary?(path) = path.start_with?("#{File.realpath(Dir.tmpdir)}/")

  # Prepended to the shell every `claude` session is started through.
  module ShellRefusal
    def capture(*command, env: {}, chdir: nil)
      reason = LiveSessionGuard.refusal(command, env || {})
      if reason
        LiveSessionGuard.refused << reason
        raise LiveSessionGuard::Violation, reason
      end

      super
    end
  end
end

Hecks::Adapters::Shell.prepend(LiveSessionGuard::ShellRefusal)

RSpec.configure do |config|
  config.after do
    refused = LiveSessionGuard.take
    raise LiveSessionGuard::Violation, refused.first unless refused.empty?
  end
end
