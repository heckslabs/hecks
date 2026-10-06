require "json"
require "open3"
require "timeout"
require "tmpdir"
require_relative "parser_differential/mutations"
require_relative "parser_differential/sweeps"

# Feeds one bluebook to `hecks-parse` and to the Ruby loader and says how the two answers relate.
# Plain Ruby, no RSpec, so a script can drive it for exploration as well as the spec.
module ParserDifferential
  ROOT     = File.expand_path("../..", __dir__)
  PARSER   = File.join(ROOT, "rust", "parser")
  BINARY   = File.join(PARSER, "target", "debug", "hecks-parse")
  FIXTURES = Dir.glob(File.join(PARSER, "tests", "fixtures", "*.bluebook")).freeze
  LOADED   = %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
                adapters/driven/prism.adapter].map { |file| File.join(ROOT, "lib", "hecks", file) }.freeze

  # Diagnostics for inputs Ruby evaluates leniently and `hecks-parse` refuses on purpose: it has no
  # lenient mode, so a bare constant or number on a line, a repeated `identified_by`, a block whose
  # body starts on the opener line, or a call where a literal belongs is an error here and a no-op,
  # a last-wins or an evaluated expression in Ruby.
  STRICTER_BY_DESIGN = [
    /is not a word .* admits/,
    /is not a word call/,
    /was written with no body/,
    /declares identified_by more than once/,
    /is not a literal/,
    /reads as \w+ \(expected one of/,
    /not yet implemented/
  ].freeze

  # What each side said: `kind` is :ok, :refused or :error; `ir` the ir.json text when :ok.
  Verdict = Struct.new(:kind, :ir, :detail, keyword_init: true)

  # How the two verdicts relate.
  Result = Struct.new(:relation, :rust, :ruby, keyword_init: true)

  module_function

  def seed = Integer(ENV.fetch("HECKS_PARSE_FUZZ_SEED", 20_261_006))

  def rounds = Integer(ENV.fetch("HECKS_PARSE_FUZZ_ITERATIONS", 120))

  def build!
    built = system("cargo", "build", chdir: PARSER, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser" unless built && File.executable?(BINARY)
  end

  # The name in the header; a NUL cannot ride in an argument, so a mutated name loses it.
  def chapter_of(text) = (text[/Hecks\.bluebook\s+"([^"]+)"/, 1] || "Fuzzed").delete("\0")

  def rust(path, chapter)
    stdout, stderr, status = Timeout.timeout(20) do
      Open3.capture3(BINARY, "chapter", "--chapter", chapter, path)
    end
    case status.exitstatus
    when 0 then Verdict.new(kind: :ok, ir: stdout)
    when 1 then Verdict.new(kind: :refused, detail: stderr)
    else Verdict.new(kind: :error, detail: "exit #{status.exitstatus.inspect}: #{stderr[0, 300]}")
    end
  end

  # The Ruby loader's verdict, exporting as `hecks project_rust` does.
  def ruby(path, chapter)
    registry = Hecks::Runtime::Registry.new(root: File.dirname(path))
    load_into(registry, path)
    ir = Hecks::Projector::Exporter.call(registry).fetch(chapter)
    Verdict.new(kind: :ok, ir: "#{JSON.pretty_generate(ir)}\n")
  rescue StandardError, ScriptError => e
    Verdict.new(kind: :refused, detail: "#{e.class}: #{e.message.lines.first&.strip}")
  end

  def load_into(registry, path)
    Hecks.with_registry(registry) do
      LOADED.each { |file| Kernel.load(file) }
      Hecks::Bluebook::MetaValidator.defer { Kernel.load(path) }
      Hecks::Bluebook::MetaValidator.judge_deferred!(Hecks.current_registry)
    end
  end

  # :both_ok_same, :both_ok_differ, :rust_only, :ruby_only, :both_refuse, or :rust_error.
  def compare(path, chapter)
    left  = rust(path, chapter)
    right = ruby(path, chapter)
    Result.new(relation: relate(left, right), rust: left, ruby: right)
  end

  def relate(left, right)
    return :rust_error if left.kind == :error
    return left.ir == right.ir ? :both_ok_same : :both_ok_differ if left.kind == :ok && right.kind == :ok
    return :rust_only if left.kind == :ok

    right.kind == :ok ? :ruby_only : :both_refuse
  end

  # True when `result` is a relation the design allows: Ruby judging what the parser only reads,
  # or the parser being stricter in one of the documented ways.
  def acceptable?(result)
    case result.relation
    when :rust_error, :both_ok_differ then false
    when :ruby_only then STRICTER_BY_DESIGN.any? { |pattern| result.rust.detail.match?(pattern) }
    else true
    end
  end
end
