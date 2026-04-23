# lib/hecks_specializer.rb
#
# Hecks::Specializer — i51 Futamura specializer driver
#
# Single entry point for every specializer target. Loads the target's
# shape fixtures via `hecks-life dump-fixtures`, dispatches to the
# target module's #emit, returns the Rust source.
#
# Replaces the Phase A/B per-target bin/specialize-* scripts. The
# common machinery (fixture loading, CLI, diff) lives here; each
# target module holds its emission logic.
#
# Target modules discovered at load-time from lib/hecks_specializer/*.rb.
# Each module must define:
#   REPO_ROOT, SHAPE, TARGET_RS — as module constants
#   class-level #emit -> String — returns the Rust source
# (Convention, not a formal contract yet — Phase C will lift the
# contract into a bluebook too.)
#
# Usage from Ruby:
#   require "hecks_specializer"
#   rust = Hecks::Specializer.emit(:validator)
#
# Usage from CLI (bin/specialize):
#   bin/specialize validator
#   bin/specialize validator --diff
#   bin/specialize dump --output hecks_life/src/dump.rs

require "json"
require "open3"
require "pathname"

module Hecks
  module Specializer
    REPO_ROOT = Pathname.new(File.expand_path("..", __dir__))
    HECKS_LIFE = REPO_ROOT.join("hecks_life/target/release/hecks-life")

    # Registered target modules. Keys are the target names used on the
    # CLI (matches SpecializerTarget.name in specializer.fixtures).
    @targets = {}

    class << self
      # Called by each target module to register itself.
      def register(name, mod)
        @targets[name.to_s] = mod
      end

      def targets
        @targets.keys.sort
      end

      def target_module(name)
        @targets[name.to_s] or raise ArgumentError,
          "unknown specializer target: #{name.inspect}. " \
          "Known: #{targets.join(', ')}"
      end

      # Run a named target and return the emitted Rust as a String.
      def emit(name)
        target_module(name).new.emit
      end

      # Load the shape fixtures for a given path. Shared by every target.
      def load_fixtures(shape_path)
        raise "hecks-life not built: #{HECKS_LIFE}" unless HECKS_LIFE.exist?
        out, err, status = Open3.capture3(HECKS_LIFE.to_s, "dump-fixtures", shape_path.to_s)
        raise "dump-fixtures failed: #{err}" unless status.success?
        JSON.parse(out)["fixtures"]
      end

      # Read a .rs.frag snippet file, stripping the leading //-comment
      # header. Everything from the first non-comment, non-empty line
      # onward is returned verbatim (specializers interpolate as fn body).
      def read_snippet_body(path)
        raise "snippet missing: #{path}" unless File.exist?(path)
        lines = File.read(path).lines
        start = lines.find_index { |l| !l.strip.empty? && !l.strip.start_with?("//") }
        lines[start..].join
      end
    end

    # ---- Shared base for target modules -----------------------------
    #
    # Mixin that gives each target:
    #   #initialize       — loads fixtures from self.class::SHAPE
    #   #by_aggregate     — group helper
    #   #read_snippet_body — delegate to module-level helper
    module Target
      def initialize
        @fixtures = Hecks::Specializer.load_fixtures(self.class::SHAPE)
      end

      def by_aggregate(name)
        @fixtures.select { |f| f["aggregate"] == name }
      end

      def read_snippet_body(path)
        Hecks::Specializer.read_snippet_body(path)
      end
    end
  end
end

# Auto-load every target module. Each require'd file is expected to
# call Hecks::Specializer.register(name, klass) at load time.
Dir[File.expand_path("hecks_specializer/*.rb", __dir__)].sort.each do |path|
  require path
end
