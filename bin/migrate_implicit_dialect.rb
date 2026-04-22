#!/usr/bin/env ruby
# bin/migrate_implicit_dialect.rb
#
# One-shot migration: rewrites implicit-dialect .bluebook files to explicit
# dialect so the ImplicitSyntax parser path can be deleted.
#
# [antibody-exempt: one-shot migration script for i24 — retires immediately
# after running; not a runtime dependency]
#
# Translations applied line-by-line:
#
#   1. Attribute shorthand:
#        String :name           → attribute :name, String
#        Float :weight, default: 0.0
#                               → attribute :weight, Float, default: 0.0
#
#   2. PascalCase sugar (context-aware):
#        Topping do ... end     → value_object "Topping" do ... end
#        ReceiveSpecimen do ... end    (if body has emits/given/then_set/
#                                        reference_to/role)
#                               → command "ReceiveSpecimen" do ... end
#
# Usage:
#   bin/migrate_implicit_dialect.rb <path-or-glob> [<path-or-glob> ...]
#
# Rewrites files in place, preserving trailing newlines. Skip verification is
# handled by the caller diffing canonical IR before/after.

require "pathname"

TYPES = %w[String Integer Float Boolean TrueClass Symbol Date DateTime Time UUID Money].freeze
TYPE_RX = Regexp.new("^(\\s*)(#{TYPES.join('|')})\\s+:(\\w+)(.*)$")
# Matches:  Indent PascalName do <optional trailing>
# Trailing is tolerated but unusual (e.g. trailing comment). We only rewrite
# bare `Name do`. If there are args, we leave the line alone.
PASCAL_DO_RX = /^(\s*)([A-Z][A-Za-z0-9_]*)\s+do\s*$/

COMMAND_MARKERS = %w[emits then_set given reference_to role].freeze

def migrate(content)
  lines = content.split("\n", -1)  # -1 preserves trailing empty strings
  # First pass: rewrite attribute shorthand
  lines = lines.map { |ln| rewrite_attribute(ln) }
  # Second pass: scan for PascalCase do blocks and rewrite
  rewrite_pascal_blocks(lines)
  lines.join("\n")
end

def rewrite_attribute(line)
  m = TYPE_RX.match(line)
  return line unless m
  indent, type, name, rest = m[1], m[2], m[3], m[4]
  "#{indent}attribute :#{name}, #{type}#{rest}"
end

def rewrite_pascal_blocks(lines)
  # Walk lines. When a Pascal `do` line is found, scan for its matching `end`
  # using a `do`/`end` depth counter, then decide command vs value_object.
  # We use the INDENT of the opening line and match against the first `end`
  # at that same indent level — more robust than counting `do`/`end` tokens
  # in bluebook sources (which contain strings like "end of operations").
  i = 0
  while i < lines.length
    m = PASCAL_DO_RX.match(lines[i])
    if m
      indent, name = m[1], m[2]
      end_idx = find_matching_end_by_indent(lines, i, indent)
      if end_idx
        body = lines[(i + 1)..(end_idx - 1)].join("\n")
        kind = classify_body(body)
        lines[i] = "#{indent}#{kind} \"#{name}\" do"
      end
    end
    i += 1
  end
end

# Finds the first line after `start` that contains exactly `<indent>end` —
# i.e. `end` at the same indent as the opening Pascal-do line. Bluebook
# files are consistently indented, so this is both simpler and more robust
# than counting do/end tokens (which misfire on strings like "end of day").
def find_matching_end_by_indent(lines, start, indent)
  target = "#{indent}end"
  j = start + 1
  while j < lines.length
    # rstrip to ignore trailing whitespace; stop when we hit the matching `end`
    return j if lines[j].rstrip == target
    j += 1
  end
  nil
end

def classify_body(body)
  COMMAND_MARKERS.any? { |marker| body =~ /\b#{marker}\b/ } ? "command" : "value_object"
end

def expand_paths(args)
  paths = []
  args.each do |arg|
    if File.file?(arg)
      paths << arg if arg.end_with?(".bluebook")
    elsif File.directory?(arg)
      paths.concat(Dir.glob(File.join(arg, "**", "*.bluebook")))
    else
      paths.concat(Dir.glob(arg))
    end
  end
  paths.select { |p| p.end_with?(".bluebook") }.uniq.sort
end

def process_file(path)
  original = File.read(path)
  migrated = migrate(original)
  return :unchanged if migrated == original
  File.write(path, migrated)
  :changed
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    warn "usage: bin/migrate_implicit_dialect.rb <path-or-glob> [...]"
    exit 1
  end

  paths = expand_paths(ARGV)
  if paths.empty?
    warn "no .bluebook files matched"
    exit 1
  end

  changed = 0
  unchanged = 0
  paths.each do |path|
    case process_file(path)
    when :changed
      changed += 1
      puts "migrated: #{path}"
    when :unchanged
      unchanged += 1
    end
  end
  puts "---"
  puts "migrated:  #{changed}"
  puts "unchanged: #{unchanged}"
  puts "total:     #{paths.length}"
end
