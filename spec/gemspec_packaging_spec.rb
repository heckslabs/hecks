require "hecks"

# What 1.5.0 shipped without Compliance at all — nothing here names
# Compliance, or any other framework member, by hand. Both checks below
# walk the SAME glob-derived sources `Hecks::Framework.members` and
# `hecks.gemspec` already use, so a future framework member (or any
# other file added under lib/) is covered automatically; nothing needs
# adding to a list when one is.
RSpec.describe "gem packaging" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, "hecks.gemspec")) }

  it "packages every file `Hecks::Framework.members` finds" do
    packaged = gemspec.files.to_set

    missing = Hecks::Framework.members.values.reject do |path|
      packaged.include?(Pathname.new(path).relative_path_from(root).to_s)
    end

    message = "not in the packaged gem: #{missing.join(', ')} — a symlink pointing outside lib/ " \
              "never survives `gem build` (RubyGems drops it silently); the real content has to " \
              "live inside lib/ itself"
    expect(missing).to be_empty, message
  end

  it "carries no symlink under lib/ — one pointing outside it is silently dropped by `gem build`" do
    symlinked = Dir.glob(File.join(root, "lib/**/*"), File::FNM_DOTMATCH).select { |path| File.symlink?(path) }
    names = symlinked.map { |path| Pathname.new(path).relative_path_from(root) }

    message = "symlink(s) under lib/: #{names.join(', ')} — RubyGems warns and drops these from the " \
              "packaged gem regardless of where they point; the real content has to be a real file " \
              "inside lib/, with any symlink pointing the other way, from outside lib/ back in"
    expect(symlinked).to be_empty, message
  end
end
