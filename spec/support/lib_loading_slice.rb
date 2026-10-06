require "open3"

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
      _out, err, status = load_in_subprocess(feature)
      failures << "#{feature}:\n#{err.lines.first(3).join}" unless status.success?
    end
  end

  def broken_features(features)
    failures = Queue.new
    work = Queue.new
    features.each { |feature| work << feature }
    Array.new(8) { Thread.new { load_features_from(work, failures) } }.each(&:join)
    [].tap { |list| list << failures.pop until failures.empty? }
  end

  def standalone_failure_message(broken)
    "these files no longer load standalone — each needs to require what it references:\n\n" \
      "#{broken.sort.join("\n")}"
  end
end
