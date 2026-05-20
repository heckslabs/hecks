# frozen_string_literal: true
#
# TranscriptWalker — walks Claude Code transcript JSONL files and tallies
# every tool_use block's name. Used by bin/update-tool-cache to mint the
# hot-path roster.
#
# Transcripts live at ~/.claude/projects/<project>/<session-id>.jsonl.
# Each line is one JSON object ; tool calls show up as :
#
#   {"type":"assistant","message":{"content":[
#     {"type":"tool_use","name":"<tool-name>","id":"...","input":{...}}
#   ]}}
#
# We tally call_count per tool name and keep the most-recent last_seen_at.
# Descriptions are not in transcripts (they're on the tool schema, not the
# call) ; bin/storehouse-tools fills them in from a separate description-
# fetch pass when known.
#
# Usage :
#
#   stats = TranscriptWalker.walk('/Users/x/.claude/projects', days: 14)
#   # => { "mcp__storehouse__storehouse__dispatch" =>
#   #        { count: 912, last_seen: "2026-05-20T11:42:00Z", description: nil },
#   #      "FileTool.Edit" => { count: 233, ... }, ... }
#
# Returns a hash sorted by call count descending.

require 'json'
require 'time'

module TranscriptWalker
  module_function

  # Walk every *.jsonl under `root` modified within `days` days and return
  # { tool_name => { count:, last_seen:, description: } } sorted by count.
  def walk(root, days: 14)
    cutoff = Time.now - (days * 86_400)
    stats = Hash.new { |h, k| h[k] = { count: 0, last_seen: nil, description: nil } }

    Dir.glob(File.join(root, '*', '*.jsonl')).each do |path|
      next if File.mtime(path) < cutoff

      tally_file(path, stats)
    end

    stats.sort_by { |_, v| -v[:count] }.to_h
  end

  # Tally tool_use blocks in one transcript file. Mutates `stats` in place.
  def tally_file(path, stats)
    File.foreach(path) do |line|
      obj = safe_parse(line) || next
      next unless obj['type'] == 'assistant'

      message = obj['message']
      next unless message.is_a?(Hash)

      content = message['content']
      next unless content.is_a?(Array)

      ts = obj['timestamp']

      content.each do |block|
        next unless block.is_a?(Hash)
        next unless block['type'] == 'tool_use'

        name = block['name']
        next unless name.is_a?(String) && !name.empty?

        record = stats[name]
        record[:count] += 1
        record[:last_seen] = newer(record[:last_seen], ts)
      end
    end
  rescue Errno::EACCES, Errno::ENOENT
    # Transient file errors — skip and continue. Transcripts that are
    # being actively written may briefly fail to read.
  end

  def safe_parse(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def newer(a, b)
    return b if a.nil?
    return a if b.nil?

    ta = parse_time(a)
    tb = parse_time(b)
    return b if ta.nil?
    return a if tb.nil?

    ta >= tb ? a : b
  end

  def parse_time(value)
    Time.parse(value)
  rescue ArgumentError, TypeError
    nil
  end
end
