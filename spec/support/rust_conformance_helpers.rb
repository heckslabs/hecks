# Helpers shared by rust_conformance_spec.rb and rust_conformance_fuzz_spec.rb, so both agree on
# what a known boundary is.
require "fileutils"
require_relative "../../lib/hecks/rust_build/native_build"
require_relative "../../lib/hecks/fuzzing/nondeterministic"

module RustConformanceHelpers
  # Raised when a declared feature fails to build; nil is reserved for "feature not declared".
  BuildFailed = Hecks::RustBuild::NativeBuild::BuildFailed

  class << self
    # @return [Hash] the process-wide build cache, keyed on [rust_dir, domain_feature]
    def build_cache = Hecks::RustBuild::NativeBuild.cache
  end

  # Builds the binary for `domain_feature` once per (rust_dir, feature) and memoizes the result;
  # the build lives in `Hecks::RustBuild::NativeBuild`, which the gem carries.
  def build_rust_for(domain_feature, rust_dir)
    Hecks::RustBuild::NativeBuild.build_rust_for(domain_feature, rust_dir)
  end

  # Strips Rust-only `emitted_*` flag fields (ADR 0049) at every nesting level, in place;
  # Ruby's records never carry them.
  # @param value [Object] the Rust output fragment to strip, typically a
  #   parsed-JSON `Hash` or `Array`; a scalar is returned unchanged
  # @return [Object] `value`, mutated in place with every `emitted_*` key
  #   removed at every nesting level
  def strip_emitted_flags!(value)
    case value
    when Hash
      value.reject! { |k, _| k.start_with?("emitted_") }
      value.each_value { |v| strip_emitted_flags!(v) }
    when Array
      value.each { |v| strip_emitted_flags!(v) }
    end
    value
  end

  # Wall-clock `event` keys that Ruby's replay projection already omits, string-keyed for Rust JSON.
  NONDETERMINISTIC_EVENT_KEYS = Hecks::Fuzzing::Nondeterministic.names(:event).map(&:to_s).freeze

  # Removes `NONDETERMINISTIC_EVENT_KEYS` from Rust's JSON output at every nesting level, in place.
  def strip_occurred_at!(value)
    case value
    when Hash
      value.reject! { |k, _| NONDETERMINISTIC_EVENT_KEYS.include?(k) }
      value.each_value { |v| strip_occurred_at!(v) }
    when Array
      value.each { |v| strip_occurred_at!(v) }
    end
    value
  end

  # Policy names in Rust's `cross_domain_reactions`, which Ruby delivers in-process but Rust's
  # kernel cannot yet resolve.
  def cross_domain_policy_names(rust_output)
    rust_output.fetch("cross_domain_reactions").flatten.to_set { |r| r["policy"] }
  end

  # Rust's JSON parser reads every number as `f64`, so integers beyond 2**53 are already rounded
  # on the wire; normalize both sides before comparing. Applies to echoed query args only.
  def reduce_to_wire_precision(value)
    case value
    when Integer then value.abs < (1 << 53) ? value : value.to_f
    when Hash    then value.transform_values { |v| reduce_to_wire_precision(v) }
    when Array   then value.map { |v| reduce_to_wire_precision(v) }
    else value
    end
  end
end
