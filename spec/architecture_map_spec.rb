require "spec_helper"

# THE MAP CANNOT SILENTLY GO OUT OF DATE ABOUT WHAT EXISTS.
#
# `docs/architecture-map.md` answers "what this system currently is" — the
# counterpart to `docs/decisions/`, which answers "why." A map that nothing
# checks rots, and the previous version of that file is the proof: it omitted
# `rust/host/` (11,081 lines) and `rust/lsp/` entirely, and claimed
# `rust/src/kernel/{expr,dispatch}.rs` was "the one part of this tree someone
# still writes by hand" — wrong by roughly a factor of twenty. Both errors are
# the same shape: a subsystem existed and the map did not know.
#
# This gate is deliberately NARROW. It answers "is every top-level subsystem
# named at all," never "is what the map says about it true" — no spec can check
# prose. Naming is the failure mode that actually happened twice, it is
# mechanically checkable, and a directory absent from the map cannot lie about
# itself the way a stale sentence can. The same reasoning
# `bin/rust_kernel_coverage` gives for checking file PRESENCE rather than
# scanning for a marker comment.
#
# Numbers in the map are deliberately NOT checked here. They are stated with
# the command that re-derives them so a reader can verify one directly; pinning
# them in a spec would turn every ordinary code change into a documentation
# failure, which is how a gate gets deleted rather than obeyed.
RSpec.describe "docs/architecture-map.md names every subsystem" do
  MAP_PATH = File.join(InMemoryDomain::ROOT, "docs/architecture-map.md")
  MAP = File.read(MAP_PATH).freeze

  # A subsystem counts as named if the map mentions its path. `lib/hecks/forms`
  # matches whether the map wrote `forms/`, `lib/hecks/forms/` or
  # `lib/hecks/forms/field_shape.rb` — the check is that the reader can find it,
  # not that it was spelled one exact way.
  def named?(prefix, dir) = MAP.include?("#{prefix}/#{dir}") || MAP.match?(%r{^\s*#{Regexp.escape(dir)}/})

  def self.subdirectories_of(path)
    Dir.children(File.join(InMemoryDomain::ROOT, path))
       .select { |entry| File.directory?(File.join(InMemoryDomain::ROOT, path, entry)) }
       .reject { |entry| entry.start_with?(".") }
       .sort
  end

  it "the map exists and says what it is for" do
    expect(MAP).to include("what this system currently is")
  end

  { "lib/hecks" => subdirectories_of("lib/hecks"), "rust" => subdirectories_of("rust") }.each do |prefix, dirs|
    dirs.each do |dir|
      it "names #{prefix}/#{dir}" do
        expect(named?(prefix, dir)).to be(true),
                                       "#{prefix}/#{dir} exists in the tree and docs/architecture-map.md never " \
                                       "mentions it. Either add it to the map (with what it is, and a measured " \
                                       "size if it carries code), or — if it genuinely does not belong in a map " \
                                       "of the system — say so there explicitly rather than leaving it absent."
      end
    end
  end
end
