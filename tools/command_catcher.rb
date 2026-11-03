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

module CommandCatcher
  NOISE = %w[cd ls cat echo pwd true false export set unset head tail sleep].freeze
  MIN_COUNT = 3
  MIN_SESSIONS = 2
  MIN_SUCCESS = 0.8
  WORD = /\A[a-z][a-z0-9_-]*\z/

  module_function

  def default_log
    ENV.fetch("HECKS_CATCH_LOG") { File.join(Dir.home, ".claude", "hecks-dev", "bash-calls.jsonl") }
  end

  # Records one PostToolUse payload. Never raises: a hook must not break the tool call.
  def record(payload, log: default_log)
    command = payload.dig("tool_input", "command").to_s.strip
    return if command.empty?

    code = payload.dig("tool_response", "exit_code") || payload.dig("tool_response", "exitCode")
    row = {
      "at" => Time.now.utc.iso8601,
      "session" => payload["session_id"].to_s,
      "shape" => shape(command),
      "ok" => code.nil? || code.to_i.zero?
    }
    FileUtils.mkdir_p(File.dirname(log))
    File.open(log, "a") { |f| f.puts(JSON.generate(row)) }
  rescue StandardError
    nil
  end

  # "bundle exec rspec spec/x_spec.rb --format doc" => "bundle exec rspec <arg>"
  # Only the leading bare words survive; the first path, flag, number or quote becomes <arg>.
  def shape(command)
    head = command.split(/\s*(?:\|\||&&|\||;)\s*/).first.to_s
    tokens = begin
      Shellwords.split(head)
    rescue ArgumentError
      head.split
    end
    tokens = tokens.drop_while { |t| t.match?(/\A[A-Za-z_]+=/) }
    words = tokens.take_while { |t| t.match?(WORD) }
    return nil if words.empty?

    rest = tokens.drop(words.size)
    rest.empty? ? words.join(" ") : "#{words.join(" ")} <arg>"
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
    rows
      .select { |r| r["shape"] }
      .group_by { |r| r["shape"] }
      .map do |shape, group|
        {
          shape: shape,
          count: group.size,
          sessions: group.map { |r| r["session"] }.uniq.size,
          success: group.count { |r| r["ok"] }.fdiv(group.size).round(2)
        }
      end
      .reject { |c| NOISE.include?(c[:shape].split.first) }
      .select { |c| c[:count] >= MIN_COUNT && c[:sessions] >= MIN_SESSIONS && c[:success] >= MIN_SUCCESS }
      .sort_by { |c| -c[:count] }
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
end

if __FILE__ == $PROGRAM_NAME
  mode = ARGV.shift
  case mode
  when "record"
    begin
      CommandCatcher.record(JSON.parse($stdin.read))
    rescue JSON::ParserError
      nil
    end
    exit 0
  when "propose"
    aggregate = nil
    log = CommandCatcher.default_log
    args = ARGV.dup
    while (arg = args.shift)
      case arg
      when "--aggregate" then aggregate = args.shift
      when "--log" then log = args.shift
      end
    end
    abort "usage: propose --aggregate NAME [--log PATH]" unless aggregate

    found = CommandCatcher.candidates(CommandCatcher.load_rows(log))
    if found.empty?
      puts "No recurring shapes yet in #{log}."
    else
      found.each { |c| puts CommandCatcher.proposal(c, aggregate: aggregate), "" }
    end
  else
    abort "usage: command_catcher.rb record | propose --aggregate NAME [--log PATH]"
  end
end
