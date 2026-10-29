# frozen_string_literal: true

module Hecks
  module Tools
    module MoveDisables
      # Why each cop is departed from, written once in the config. A cop moved without an entry here
      # refuses the move, so a reason is never left out.
      REASONS = {
        "Metrics/AbcSize"                => "spec boot helpers wire a whole runtime; splitting them hides the wiring",
        "Metrics/MethodLength"           => "spec boot helpers wire a whole runtime; splitting them hides the wiring",
        "Metrics/CyclomaticComplexity"   => "spec boot helpers wire a whole runtime; splitting them hides the wiring",
        "Metrics/PerceivedComplexity"    => "spec boot helpers wire a whole runtime; splitting them hides the wiring",
        "Metrics/ParameterLists"         => "keyword and positional signatures callers spell out; a parameter object hides them",
        "Naming/PredicateMethod"         => "returns the operation's outcome, a row, value or verdict; the name is the verb",
        "Naming/PredicatePrefix"         => "the DSL verb is the name a bluebook author writes",
        "Style/MutableConstant"          => "registries and caches are mutable by design (see the ThreadSafety override)",
        "Style/GlobalStdStream"          => "a forked child reopens the standard streams to capture its output",
        "Style/FormatStringToken"        => "the text is curl's own token or table row text, not a Ruby format string",
        "Style/EvalWithLocation"         => "deliberately without file and line: exercises the untraceable-source refusal",
        "Style/ComparableBetween"        => "the bluebook expression language refuses between?; the spelling is under test",
        "Lint/UnusedBlockArgument"       => "the block parameter's name is read by reflection",
        "Lint/RescueException"           => "rolls back, then re-raises",
        "Lint/InheritException"          => "deliberately escapes `rescue => e`, which catches StandardError only",
        "Lint/IneffectiveAccessModifier" => "`private` does not reach `def self.`; the entry point is public on purpose",
        "Lint/StructNewOverride"         => "the member shadows a Struct or Enumerable method on purpose; the file says which",
        "RSpec/Output"                   => "the spec exercises console output",
        "RSpec/RemoveConst"              => "the probe constant must not outlive the example",
        "RSpec/ExampleLength"            => "a scenario example carries its whole bluebook fixture",
        "Security/MarshalLoad"           => "reads our own cache or the gem's own file, never external input",
        "Layout/LineLength"              => "characterization tables with one long row per line",
        "Layout/HashAlignment"           => "the multi-line procs overrun LineLength under table alignment"
      }.freeze
    end
  end
end
