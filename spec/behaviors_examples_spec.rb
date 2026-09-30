require "hecks/behaviors/rspec"

# Every `.behaviors` file the corpus carries, run as ordinary rspec
# examples through the shim a consumer's own suite would use — the
# sibling of spec/guides_spec.rb's doctests and spec/corpus_spec.rb's
# JSON step-lists.
#
# The Hecks domain's own `.behaviors` sit beside its bluebooks in lib/hecks/hecks/.
[File.join(InMemoryDomain::ROOT, "examples", "**", "*.behaviors"),
 File.join(InMemoryDomain::ROOT, "lib", "hecks", "hecks", "*.behaviors")].flat_map { |glob| Dir.glob(glob) }.each do |path|
  Hecks::Behaviors::RSpec.describe_file(path)
end
