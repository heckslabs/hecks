# frozen_string_literal: true

# A stand-in for `Hecks::Adapters::Shell` that starts nothing: it answers the outputs and statuses
# it was given, in order (the last one repeats), and remembers each command it was asked to run.
# Codebase adapter specs hand it to a task so no script, gate or network call happens.
class FakeCodebaseShell
  # @return [Array<Hash>] each ask: `command` (without the Ruby program), `env` and `chdir`
  attr_reader :asked

  # @param answers [Array<Array>] `[out, status]` pairs, one for each ask; a bare output is status 0
  def initialize(*answers)
    @answers = answers.empty? ? [["", 0]] : answers.map { |answer| Array(answer) }
    @asked = []
  end

  # @return [Hash] the environment of the first ask
  def env = @asked.first[:env]

  # @return [Array<String>] the first ask's command, without the Ruby program
  def command = @asked.first[:command]

  # Records the ask and answers the next output.
  #
  # @return [Hecks::Adapters::Shell::Result] the canned answer
  def capture(*command, env: {}, chdir: nil)
    @asked << { command: command[1..], env: env, chdir: chdir, program: command.first }
    out, status = next_answer
    Hecks::Adapters::Shell::Result.new(out, "", Struct.new(:success?, :exitstatus).new(status.zero?, status))
  end

  # Stands in for `Hecks::Tools.run`: records the tool asked for (as `command`, the tool's name
  # then its arguments), prints the next output as the tool would, and answers its status.
  #
  # @example
  #   allow(Hecks::Tools).to receive(:run, &shell.method(:run_tool))
  # @return [Integer] the canned exit status
  def run_tool(name, argv, root: nil)
    @asked << { command: [name, *argv], env: {}, chdir: root, program: name }
    out, status = next_answer
    # The tool prints and the caller captures it, so this must reach `$stdout`.
    print out # rubocop:disable RSpec/Output
    status
  end

  private

  def next_answer
    out, status = @answers[[@asked.size, @answers.size].min - 1]
    [out, status || 0]
  end
end
