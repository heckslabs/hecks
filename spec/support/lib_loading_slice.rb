require "open3"
require "hecks/pipeline_board/adapters/load_guard"
require "hecks/rust_build/world_rows"

# What the three load_hygiene_lib_*_spec.rb files share: every lib file loads standalone, in a fresh
# process, checked one slice at a time. Every `of`-th file of the sorted list belongs to slice
# `index`, so the slices are about the same size, and each spec file is one unit a shard can place.
module LibLoadingSlice
  def lib_dir = File.expand_path("../../lib", __dir__)

  def load_in_subprocess(feature) = Open3.capture3("ruby", "-I", lib_dir, "-e", "require #{feature.inspect}")

  # bluebook internals are frozen, so their namespace wrappers carry the requires that
  # standalone loading needs; the wrappers are held to the standard, the internals exempt.
  def bluebook_wrappers = %w[hecks/bluebook hecks/bluebook/ir hecks/bluebook/dsl hecks/bluebook/expression]

  def standalone_features
    Dir[File.join(lib_dir, "hecks", "**", "*.rb")]
      .map { |file| file.sub("#{lib_dir}/", "").delete_suffix(".rb") }
      .reject { |f| f.start_with?("hecks/bluebook/") && !bluebook_wrappers.include?(f) }
      .sort
  end

  # @return [Array<String>] the features of slice `index` (0-based) of `of`
  def slice_of_features(index, of)
    standalone_features.each_with_index.select { |_, i| i % of == index }.map(&:first)
  end

  # Takes features off `work` until it is empty, adding a line to `failures` for each that fails.
  def load_features_from(work, failures)
    until work.empty?
      feature = begin
        work.pop(true)
      rescue ThreadError
        break
      end
      wait_for_room
      _out, err, status = load_in_subprocess(feature)
      failures << "#{feature}:\n#{err.lines.first(3).join}" unless status.success?
    end
  end

  # How many fresh processes a slice runs at once. A developer machine runs three slices together
  # beside its other work, so each takes two (six in all) and a landing's gate holds the load near
  # its limit; CI gives a shard its own cores, so it takes eight.
  def load_workers = ENV["CI"] ? 8 : 2

  # The 1-minute load above which a worker starts no process: the Tickets world's
  # `dispatch_max_load` (overlay included, as a machine setting), the limit a fill stops at.
  def load_limit = Float(Hecks::RustBuild::WorldRows.row(File.dirname(lib_dir), "dispatch_max_load")[:limit] || 10.0)

  # The most seconds a slice waits for room in all, across its workers. It stays well under the
  # world's `spec_bounds` file bound (600), so a loaded machine slows a slice and never ends it.
  def load_wait_budget = 120

  # How many times a worker looks at the load before it starts anyway, so a machine kept busy by
  # other work slows the slice and never hangs it.
  def load_wait_ticks = 60

  # @return [Float] the machine's 1-minute load now
  def machine_load = Hecks::Adapters::PipelineBoard::LoadGuard.reading

  # Waits while the machine is over `load_limit`, at most `load_wait_ticks` looks and never past the
  # slice's wait deadline; CI never waits.
  def wait_for_room
    return if ENV["CI"]

    load_wait_ticks.times do
      break unless machine_load > load_limit && wait_left?

      pause
    end
  end

  def start_wait_budget = @wait_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + load_wait_budget

  def wait_left? = @wait_deadline.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) < @wait_deadline

  def pause = Queue.new.pop(timeout: 2)

  def broken_features(features)
    start_wait_budget
    failures = Queue.new
    work = Queue.new
    features.each { |feature| work << feature }
    Array.new(load_workers) { Thread.new { load_features_from(work, failures) } }.each(&:join)
    [].tap { |list| list << failures.pop until failures.empty? }
  end

  def standalone_failure_message(broken)
    "these files no longer load standalone — each needs to require what it references:\n\n" \
      "#{broken.sort.join("\n")}"
  end
end
