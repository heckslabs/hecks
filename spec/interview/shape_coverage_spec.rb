require "spec_helper"
require "open3"

# `bin/interview shape`'S KNOWLEDGE WAS ONLY AS WIDE AS ONE NIGHT'S
# INCIDENTS — every note it carries (the closed-set sequence, the
# `owner_id` reserved head, a read model's one-root-at-a-time limit) was
# documented because THIS interview happened to hit it, not because
# every verb in the meta-language was deliberately exercised. `Policy`,
# `ProcessManager`, `Handler`, `Dispatch`, `Entity` — none of those got
# touched building BurningManPrep. This is not a gotcha-documentation
# gate (this build cannot know what it never triggered) — it is the
# narrower, honest claim that IS checkable: `shape` does not crash on
# ANY real verb the language declares, across all three meta chapters
# (`Bluebook`, `World`, `Hecksagon`), not just the ones this build's
# proposals happened to name.
RSpec.describe "bin/interview shape, across the whole meta-language" do
  BIN = File.join(InMemoryDomain::ROOT, "bin/interview")

  def self.every_meta_verb
    registry = Hecksagain::Bluebook::MetaValidator.grammar_registry
    %w[Bluebook World Hecksagon].flat_map do |chapter_name|
      chapter = registry.bluebook(chapter_name)
      next [] unless chapter

      chapter.aggregates.flat_map do |aggregate|
        aggregate.commands.map { |command| "#{chapter_name}::#{aggregate.name}.#{command.hecks_name}" }
      end
    end
  end

  every_meta_verb.each do |verb|
    it "renders a shape for #{verb} without crashing" do
      stdout, status = Open3.capture2(BIN, "shape", verb)
      expect(status).to be_success, "bin/interview shape #{verb.inspect} exited #{status.exitstatus}:\n#{stdout}"
      expect(stdout).not_to be_empty
      expect(stdout).to include(verb)
    end
  end
end
