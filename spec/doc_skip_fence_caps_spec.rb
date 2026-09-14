require "spec_helper"
require_relative "support/doctest"
require_relative "support/doctest_names"

# A ```ruby skip FENCE IS AN EXAMPLE THAT LEFT THE SUITE — shown to the
# reader, never run (spec/support/doctest.rb), so nothing notices the day
# it stops being true. Some are honest (a Rails controller, an adapter
# skeleton with `...` bodies); none is checked. This ratchet keeps the
# count from growing and makes every conversion to a real fence stick:
#
#   - a file over its cap fails: turn the new fence into a running one
#     (```ruby, or ```ruby boot with a hidden doctest:boot setup);
#   - a file under its cap fails too: lower the cap to the new count, so
#     the fence you just converted can't quietly come back;
#   - a file with no entry has a cap of zero.
#
# Scope is exactly what the doctest gate parses (DoctestNames.all: the
# guides, README.md and the DSL reference) — a skip fence means "not run"
# only where the rest of the file IS run.
RSpec.describe "```ruby skip fences in executable documentation" do
  SKIP_FENCE_CAPS = {
    "README.md"                                                => 5,
    "docs/implemented/guides/aggregates-and-value-objects.md"  => 16,
    "docs/implemented/guides/behaviors.md"                     => 6,
    "docs/implemented/guides/commands.md"                      => 1,
    "docs/implemented/guides/entities.md"                      => 1,
    "docs/implemented/guides/extending-hecks.md"               => 4,
    "docs/implemented/guides/lifecycles.md"                    => 1,
    "docs/implemented/guides/policies-and-process-managers.md" => 7,
    "docs/implemented/guides/queries-and-read-models.md"       => 12,
    "docs/implemented/guides/running-a-runtime.md"             => 3,
    "docs/implemented/guides/schema-evolution.md"              => 1,
    "docs/implemented/guides/wiring.md"                        => 8,
    "docs/implemented/guides/writing-an-adapter.md"            => 11,
    "docs/implemented/reference/aggregate.md"                  => 1,
    "docs/implemented/reference/command.md"                    => 1,
    "docs/implemented/reference/dispatch.md"                   => 1,
    "docs/implemented/reference/handler.md"                    => 1,
    "docs/implemented/reference/one_of.md"                     => 1,
    "docs/implemented/reference/policy.md"                     => 1,
    "docs/implemented/reference/process_manager.md"            => 2,
    "docs/implemented/reference/value_object.md"               => 2
  }.freeze

  def self.counts
    DoctestNames.all.to_h { |path| [DoctestNames.relative(path), Doctest.parse(path).skip_fences] }
  end

  it "keeps every file at or under its cap — a new skip fence must run instead" do
    over = self.class.counts.filter_map do |file, count|
      cap = SKIP_FENCE_CAPS.fetch(file, 0)
      "#{file}: #{count} ```ruby skip fences, cap #{cap}" if count > cap
    end
    expect(over).to be_empty,
                    "#{over.join("\n")}\nmake the new fence run (```ruby / ```ruby boot) rather than raising the cap"
  end

  it "keeps every cap at the current count — a converted fence lowers the cap for good" do
    counts = self.class.counts
    stale = SKIP_FENCE_CAPS.filter_map do |file, cap|
      count = counts.fetch(file, 0)
      "#{file}: cap #{cap}, now #{count} — set its cap to #{count}#{' (delete the entry)' if count.zero?}" if cap > count
    end
    expect(stale).to be_empty, stale.join("\n")
  end

  it "counts a skip fence the way the doctest parser drops it" do
    Tempfile.create(["skip-fence-", ".md"]) do |file|
      file.write("```ruby skip\nshown\n```\n\n```text\n```ruby skip\n```\n\n```ruby\n1\n```\n")
      file.flush
      expect(Doctest.parse(file.path).skip_fences).to eq(1)
    end
  end
end
