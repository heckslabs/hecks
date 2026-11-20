# frozen_string_literal: true

module WallClock
  # Reads the spec files for timing examples: the ones tagged `:wall_clock`, and any line that
  # bounds a duration without going through `expect_wall_clock`. A source scan, so a new timing
  # example is caught before it ever runs on a slow runner.
  module Scan
    ROOT = File.expand_path("../..", __dir__)
    SELF = "spec/wall_clock_registry_spec.rb"
    TAGGED = /\bit\(?\s*"([^"]+)"(?:[^\n]*,\n\s*|[^\n]*?):wall_clock\b/
    BOUND = /(be <|be <=|be_between|between\?)/
    DURATION = /clock_gettime|realtime|second|elapsed|slowest|held_for|waited|_ms\b|timed|duration|took/

    # Lines that bound something named like a duration that is not wall-clock time: a fake clock,
    # a sum of recorded timings, or a value that only shares a word.
    NOT_WALL_CLOCK = [
      ["spec/adapters/driven/in_process_operations_spec.rb", "expect(elapsed.call).to be_between"],
      ["spec/driving_adapters/usage_log_telemetry_spec.rb", "boot_ms(now)"],
      ["spec/shard_planner_spec.rb", "by_seconds.map"],
      ["spec/project_deploy_preview_spec.rb", "second.length"],
      ["spec/quality_control_spec.rb", "second.proposed_at"],
      ["spec/fuzzing/coverage_campaign_spec.rb", "second.prefix"]
    ].freeze

    module_function

    # @return [Array<String>] every spec file but the registry spec, relative to the repository
    def files = Dir.glob("spec/**/*_spec.rb", base: ROOT) - [SELF]

    # @return [Array<Array(String, String)>] each `:wall_clock` example as [file, description]
    def tagged
      files.flat_map do |file|
        File.read(File.join(ROOT, file)).scan(TAGGED).map { |(description)| [file, description] }
      end
    end

    # @return [Array<String>] each duration bound outside `expect_wall_clock`, as "file:line: text"
    def untagged_bounds
      files.flat_map do |file|
        File.foreach(File.join(ROOT, file)).with_index(1).filter_map do |line, number|
          "#{file}:#{number}: #{line.strip}" if untagged_bound?(file, line)
        end
      end
    end

    # @param file [String] the spec file, relative to the repository
    # @param line [String] one of its lines
    # @return [Boolean] whether the line bounds a wall-clock duration directly
    def untagged_bound?(file, line)
      return false unless line.match?(BOUND) && line.match?(DURATION)

      NOT_WALL_CLOCK.none? { |(path, text)| path == file && line.include?(text) }
    end
  end
end
