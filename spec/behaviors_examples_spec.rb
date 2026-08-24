require "hecks/behaviors/rspec"

# Every `.behaviors` file the corpus carries, run as ordinary rspec
# examples through the shim a consumer's own suite would use — the
# sibling of spec/guides_spec.rb's doctests and spec/corpus_spec.rb's
# JSON step-lists.
Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "**", "*.behaviors")).each do |path|
  Hecks::Behaviors::RSpec.describe_file(path)
end
