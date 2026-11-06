# frozen_string_literal: true

# Command catcher: records Bash tool calls (via a Claude Code PostToolUse hook)
# and proposes Hecks `command` blocks for shell patterns that keep recurring.
#
#   ruby tools/command_catcher.rb record            # hook mode: JSON payload on stdin
#   ruby tools/command_catcher.rb propose --aggregate Transfer [--log PATH]
#
# Proposals print a DSL snippet only. Nothing is written into a bluebook.
# Commands are stored by shape (program + subcommands, arguments blanked),
# never by full text, so tokens and paths in arguments are not recorded.

require "json"
require "shellwords"
require "time"
require "fileutils"

# Records the shape of each Bash tool call and proposes Hecks command blocks for the ones that recur.
module CommandCatcher
  NOISE = %w[cd ls cat echo pwd true false export set unset head tail sleep].freeze
  MIN_COUNT = 3
  MIN_SESSIONS = 2
  MIN_SUCCESS = 0.8
  WORD = /\A[a-z][a-z0-9_-]*\z/
  SEGMENT = /\s*(?:\|\||&&|\||;)\s*/
  ASSIGNMENT = /\A[A-Za-z_]+=/

  module_function

  def default_log
    ENV.fetch("HECKS_CATCH_LOG") { File.join(Dir.home, ".claude", "hecks-dev", "bash-calls.jsonl") }
  end

  # Records one PostToolUse payload. Never raises: a hook must not break the tool call.
  def record(payload, log: default_log)
    command = payload.dig("tool_input", "command").to_s.strip
    return if command.empty?

    append(log, call_row(payload, command))
  rescue StandardError
    nil
  end

  # The row one tool call is recorded as: when, which session, its shape, and whether it succeeded.
  def call_row(payload, command)
    code = payload.dig("tool_response", "exit_code") || payload.dig("tool_response", "exitCode")
    { "at" => Time.now.utc.iso8601, "session" => payload["session_id"].to_s,
      "shape" => shape(command), "ok" => code.nil? || code.to_i.zero? }
  end

  # Appends one row to the log as a JSON line, creating its directory first.
  def append(log, row)
    FileUtils.mkdir_p(File.dirname(log))
    File.open(log, "a") { |f| f.puts(JSON.generate(row)) }
  end

  # "bundle exec rspec spec/x_spec.rb --format doc" => "bundle exec rspec <arg>"
  # Only the leading bare words survive; the first path, flag, number or quote becomes <arg>.
  def shape(command)
    tokens = tokens_of(command.split(SEGMENT).first.to_s).drop_while { |t| t.match?(ASSIGNMENT) }
    words = tokens.take_while { |t| t.match?(WORD) }
    return nil if words.empty?

    tokens.size > words.size ? "#{words.join(" ")} <arg>" : words.join(" ")
  end

  # The words of one pipeline segment, split as a shell would, or on spaces when it is not well quoted.
  def tokens_of(segment)
    Shellwords.split(segment)
  rescue ArgumentError
    segment.split
  end

  def load_rows(log)
    return [] unless File.exist?(log)

    File.foreach(log).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  # Shapes that recur across sessions and mostly succeed.
  def candidates(rows)
    tallies(rows).reject { |c| noise?(c) }.select { |c| recurring?(c) }.sort_by { |c| -c[:count] }
  end

  # One tally per recorded shape: how often it ran, in how many sessions, and how often it succeeded.
  def tallies(rows)
    rows.select { |r| r["shape"] }.group_by { |r| r["shape"] }.map { |shape, group| tally(shape, group) }
  end

  def tally(shape, group)
    { shape: shape, count: group.size, sessions: group.map { |r| r["session"] }.uniq.size,
      success: group.count { |r| r["ok"] }.fdiv(group.size).round(2) }
  end

  def noise?(candidate) = NOISE.include?(candidate[:shape].split.first)

  def recurring?(candidate)
    candidate[:count] >= MIN_COUNT && candidate[:sessions] >= MIN_SESSIONS && candidate[:success] >= MIN_SUCCESS
  end

  def command_name(shape)
    shape.split.reject { |w| w.include?("<") }.map { |w| w.gsub(/[^A-Za-z0-9]/, "").capitalize }.join
  end

  # A `command` block to paste inside the named aggregate.
  def proposal(candidate, aggregate:)
    <<~DSL
      # #{candidate[:count]} calls across #{candidate[:sessions]} sessions, #{(candidate[:success] * 100).round}% succeeded
      # inside aggregate "#{aggregate}":
      command "#{command_name(candidate[:shape])}" do
        role "Developer"
        goal "Run `#{candidate[:shape]}`"
      end
    DSL
  end

  # Runs the command line: `record` reads a hook payload on stdin, `propose` prints proposals.
  def main(argv)
    case argv.first
    when "record" then record_stdin
    when "propose" then propose(argv.drop(1))
    else abort "usage: command_catcher.rb record | propose --aggregate NAME [--log PATH]"
    end
  end

  def record_stdin
    record(JSON.parse($stdin.read))
  rescue JSON::ParserError
    nil
  ensure
    exit 0
  end

  def propose(args)
    options = propose_options(args)
    abort "usage: propose --aggregate NAME [--log PATH]" unless options[:aggregate]

    found = candidates(load_rows(options[:log]))
    puts "No recurring shapes yet in #{options[:log]}." if found.empty?
    found.each { |c| puts proposal(c, aggregate: options[:aggregate]), "" }
  end

  # The --aggregate and --log values named on the command line, the log defaulting to the hook's.
  def propose_options(args)
    options = { aggregate: nil, log: default_log }
    args.each_slice(2) do |flag, value|
      options[:aggregate] = value if flag == "--aggregate"
      options[:log] = value if flag == "--log"
    end
    options
  end
end

CommandCatcher.main(ARGV) if __FILE__ == $PROGRAM_NAME
