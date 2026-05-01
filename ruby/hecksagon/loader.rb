# Hecksagon::Loader
#
# Guarded loader for `.hecksagon` and `.world` source. Scans the file
# against an allow-list of DSL keywords before evaluating — anything
# outside the list is a disallowed construct and raises.
#
# The goal is the five-DSL principle: .bluebook, .hecksagon, .fixtures,
# .behaviors, .world must all be parsed declarative DSL, not arbitrary
# Ruby. This loader is the Ruby-side gate. The Rust side parses from
# scratch and is incapable of evaluating Ruby by construction.
#
# Usage:
#
#   Hecksagon::Loader.load("config.hecksagon")       # evaluates if allowed
#   Hecksagon::Loader.load_world("config.world")     # same for .world
#
# Raises Hecksagon::UnsafeHecksagonError with the offending line when
# a disallowed construct is found.
#
# Allow-lists are the parity-tested surface; anything outside them fails
# loud so drift is visible at commit time.
module Hecksagon
  # Raised when a .hecksagon/.world file contains a line that isn't on
  # the allow-list. The message carries the path, line number, and the
  # offending source so the author sees exactly what to fix.
  class UnsafeHecksagonError < StandardError; end

  module Loader
    # DSL surface allowed at the top level of a `.hecksagon` file.
    # Mirrors Hecksagon::DSL::HecksagonBuilder's public methods plus the
    # per-block keywords (allow, upstream, ...). PascalCase identifiers
    # (annotation chains like `Chat.prompt.ai_responder`) are allowed
    # too — see `allowed_line?`.
    HECKSAGON_ALLOWED = %w[
      Hecks.hecksagon adapter annotate aggregate allow capabilities concerns
      context_map domain driven driving end extension gate listens_to owned_by
      persistence port subscribe tenancy upstream downstream shared_kernel
    ].freeze

    # DSL surface allowed at the top level of a `.world` file.
    WORLD_ALLOWED = %w[
      Hecks.world audience concern description end purpose vision
    ].freeze

    # Load a `.hecksagon` file after checking every non-blank line
    # against the allow-list.
    def self.load(path)
      source = File.read(path)
      validate!(source, path, HECKSAGON_ALLOWED)
      Kernel.load(path)
    end

    # Load a `.world` file after checking every non-blank line against
    # the world allow-list. World files allow arbitrary extension-block
    # headers (heki, ollama, sqlite, claude, websocket, ...), so the
    # guard is looser than .hecksagon — any `IDENT do` line passes.
    def self.load_world(path)
      source = File.read(path)
      validate!(source, path, WORLD_ALLOWED, world: true)
      Kernel.load(path)
    end

    # Raise unless every line in `source` is on the allow-list, is a
    # comment/blank line, or is a nested block body keyword.
    def self.validate!(source, path, allowed, world: false)
      source.each_line.with_index(1) do |raw, ln|
        line = strip_comment(raw).strip
        next if line.empty?
        next if allowed_line?(line, allowed, world: world)
        raise UnsafeHecksagonError,
          "#{path}:#{ln}: disallowed construct — `#{line}`"
      end
    end

    # True if `line` is allowed. Matches if it starts with any allow-list
    # keyword, if it's a nested-body keyword (`do`, `end`, symbol/string
    # list continuation), if it's a PascalCase annotation chain, or — in
    # world mode — if it's an `IDENT do` extension-block header.
    def self.allowed_line?(line, allowed, world: false)
      # Bare structural tokens: `do`, `end`, trailing `end` punctuation.
      return true if line == "do" || line == "end" || line == "end)"
      # Continuation lines inside a multi-line `allow :A, :B,` call:
      # `:Sym, :Sym` or `:Sym` or `"String",`
      return true if line.match?(/\A[:"\w][:"\w\s,]*,?\z/)

      first_token = line.split(/[\s(,]/, 2).first.to_s
      return true if allowed.include?(first_token)

      # Continuation lines inside a multi-line `adapter :shell, …` call
      # or an indented `command "…"` / `args […]` inside an
      # `adapter :shell do … end` block. These look like a bare kwarg
      # (`name: :foo,`) or a builder method invocation (`command "…"`).
      return true if line.match?(/\A[a-z_]\w*:\s/)          # `name: :foo` kwarg
      return true if line.match?(/\A[a-z_]\w*\s+[\[":]/)    # `command "x"`, `args [...]`, `env { ... }`

      # PascalCase identifiers — annotation chains like
      # `Chat.prompt.ai_responder adapter: :claude`. Only allowed in
      # .hecksagon (where annotations live); .world has no use for
      # bare constant chains and any PascalCase call is suspicious.
      if !world && first_token.match?(/\A[A-Z]\w*(\.\w+)*\z/)
        return true
      end

      # Family A: arbitrary extension-block header in a `.world` file
      # (heki, ollama, sqlite, claude, websocket, static_assets, ...).
      if world && line.match?(/\A[a-z_]\w*\s+do(\s|;|$)/)
        return true
      end

      # Family A kv line inside an extension block: `model "bluebook"`,
      # `port 4567`, `content "a", "b"`.
      if world && line.match?(/\A[a-z_]\w*\s+[^=]/)
        return true
      end

      false
    end

    # Drop trailing `# comment` from a source line, preserving quoted
    # `#` characters inside strings.
    def self.strip_comment(line)
      in_str = false
      prev = "\0"
      line.each_char.with_index do |c, i|
        if c == '"' && prev != "\\"
          in_str = !in_str
        elsif c == "#" && !in_str
          return line[0, i]
        end
        prev = c
      end
      line
    end
  end
end
