# Hecks::Behaviors::FixturesLoader
#
# Auto-locates and loads a sibling `.fixtures` file for a `.behaviors`
# test file so cross-aggregate cascades get the seeded state they
# depend on (i4 gap 8). Two discovery paths, checked in order:
#
#   1. `<dir>/<name>.fixtures`              — flat sibling
#   2. `<dir>/fixtures/<name>.fixtures`     — conventional subdir
#
# The file, if any, is parsed via the `Hecks.fixtures` DSL (same
# registry slot as standalone fixtures loading). The loader returns
# the parsed `FixturesFile` — the runner decides when to apply it.
#
# Parity: mirrors hecks_life/src/behaviors_runner.rs fixtures_loader
# helpers, same discovery rules, same FixturesFile shape.
#
# [antibody-exempt: test runner auto-loads fixtures for cross-aggregate
# cascades (i4 gap 8); retires when behaviors runner ports to
# bluebook-dispatched form]
#
#   fixtures = FixturesLoader.find_for("path/to/pizzas.behaviors")
#   FixturesLoader.apply(rt, fixtures) if fixtures
require_relative "value"
require_relative "aggregate_state"

module Hecks
  module Behaviors
    module FixturesLoader
      module_function

      # Find the sibling .fixtures file for a given .behaviors path.
      # Returns the parsed FixturesFile or nil if no file is found.
      def find_for(behaviors_path)
        path = locate_path(behaviors_path)
        return nil unless path
        parse_file(path)
      end

      # Returns the absolute path to the fixtures file, or nil if none
      # found. Public so callers can log which file was loaded.
      def locate_path(behaviors_path)
        return nil unless behaviors_path

        dir  = File.dirname(behaviors_path)
        stem = File.basename(behaviors_path).sub(/\.(behaviors|bluebook)\z/, "")
        stem = stem.sub(/_behavioral_tests\z/, "")

        candidates = [
          File.join(dir, "#{stem}.fixtures"),
          File.join(dir, "fixtures", "#{stem}.fixtures"),
        ]
        candidates.find { |p| File.file?(p) }
      end

      # Parse a .fixtures file via the Hecks.fixtures DSL and return the
      # FixturesFile. The registry's `last_fixtures_file` accessor is the
      # canonical single-shot slot — we snapshot/restore it so concurrent
      # parses in the same process don't clobber each other's state.
      def parse_file(path)
        require "hecks"
        require "hecks/dsl/fixtures_builder"
        prev = Hecks.last_fixtures_file
        Hecks.last_fixtures_file = nil
        Kernel.load(path)
        Hecks.last_fixtures_file
      ensure
        Hecks.last_fixtures_file = prev
      end

      # Seed a fresh BehaviorRuntime with fixture data. Creates one
      # AggregateState per fixture under sequential integer ids, which
      # matches the runner's `pre_seed_singletons` id convention ("1",
      # "2", ...). The FIRST fixture per aggregate becomes the "in
      # scope" id (what references will resolve to), so tests get
      # deterministic cross-aggregate linkage.
      #
      # Returns a Hash<aggregate_name, id> so the runner can merge it
      # into its own `in_scope` map.
      def apply(rt, fixtures_file)
        in_scope = {}
        return in_scope unless fixtures_file

        by_agg = Hash.new { |h, k| h[k] = [] }
        fixtures_file.fixtures.each { |f| by_agg[f.aggregate_name] << f }

        by_agg.each do |agg_name, fixtures|
          repo = rt.repositories[agg_name]
          next unless repo # fixture references an aggregate not in domain

          fixtures.each_with_index do |fix, i|
            id = (i + 1).to_s
            state = AggregateState.new(id)
            (fix.attributes || {}).each do |key, value|
              state.set(key.to_s, Value.from(value))
            end
            repo[id] = state
            in_scope[agg_name] ||= id
          end
        end

        in_scope
      end
    end
  end
end
