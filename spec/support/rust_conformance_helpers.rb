# Helpers shared by rust_conformance_spec.rb and rust_conformance_fuzz_spec.rb, so both agree on
# what a known boundary is.
require "fileutils"
require "open3"
require_relative "../../lib/hecks/fuzzing/nondeterministic"

module RustConformanceHelpers
  # Raised when a declared feature fails to build; nil is reserved for "feature not declared".
  class BuildFailed < StandardError; end

  # Process-wide cache keyed on [rust_dir, domain_feature]: examples interleave randomly, and
  # alternating `--features` builds forces a full recompile each time.
  @build_cache = {}

  class << self
    attr_reader :build_cache
  end

  # Builds the binary for `domain_feature` once per (rust_dir, feature) and memoizes the result.
  # Answers nil when Cargo.toml declares no such feature; a failed build raises `BuildFailed`,
  # memoized too.
  def build_rust_for(domain_feature, rust_dir)
    cache = RustConformanceHelpers.build_cache
    cache_key = [rust_dir, domain_feature]
    if cache.key?(cache_key)
      raise cache[cache_key] if cache[cache_key].is_a?(BuildFailed)

      return cache[cache_key]
    end

    cargo_toml = File.read(File.join(rust_dir, "Cargo.toml"))
    return cache[cache_key] = nil unless cargo_toml =~ /^#{Regexp.escape(domain_feature)}\s*=\s*\[\]/

    begin
      cache[cache_key] = build_and_pin(domain_feature, rust_dir)
    rescue BuildFailed => e
      cache[cache_key] = e
      raise
    end
  end

  # Holds an exclusive flock from `cargo build` through the copy-out: parallel `bin/qa_sweep`
  # processes share target/debug/rust, and another build could overwrite it before it is pinned.
  # The lock file is left on disk.
  def build_and_pin(domain_feature, rust_dir)
    lock_path = File.join(rust_dir, "target", ".build_rust_for.lock")
    FileUtils.mkdir_p(File.dirname(lock_path))

    File.open(lock_path, File::CREAT | File::RDWR) do |lock|
      lock.flock(File::LOCK_EX)

      command = ["cargo", "build", "--no-default-features", "--features", domain_feature]
      begin
        _stdout, stderr, status = Open3.capture3(*command, chdir: rust_dir)
      rescue SystemCallError => e
        raise BuildFailed, "`#{command.join(' ')}` could not run in #{rust_dir}: #{e.message}"
      end
      unless status.success?
        raise BuildFailed, "`#{command.join(' ')}` failed in #{rust_dir} (exit #{status.exitstatus}) — " \
                           "#{domain_feature} is declared in Cargo.toml, so this is a build failure, " \
                           "not a missing feature:\n#{stderr}"
      end

      binary = File.join(rust_dir, "target", "debug", "rust")
      unless File.executable?(binary)
        raise BuildFailed, "`#{command.join(' ')}` succeeded in #{rust_dir} but left no executable at #{binary}:\n#{stderr}"
      end

      # `cargo build` always writes the same path; pin it per feature while still holding the lock.
      pinned = File.join(rust_dir, "target", "debug", "rust-#{domain_feature}")
      FileUtils.cp(binary, pinned)
      File.chmod(0o755, pinned)
      pinned
    end
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
