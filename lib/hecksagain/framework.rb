require_relative "runtime/registry"

module Hecksagain
  # THE REGISTRY OF FRAMEWORK BLUEBOOKS — Governance, Identity, and
  # whatever lands beside them in `framework/bluebook/`: domain-agnostic
  # chapters no single example owns, shared by reference rather than
  # copied into every domain that wants one.
  #
  # DERIVED FROM THE DIRECTORY, not hand-listed a second time — the same
  # reasoning `Assembly::CONTRACTS` gives for reading the language's own
  # fields from a table instead of restating them: a member added to
  # `framework/bluebook/` and forgotten here would be a member
  # `uses_framework` could never find, and a hand-kept list is exactly
  # the shape that goes stale in silence. `spec/corpus_spec.rb`'s own
  # `FRAMEWORK_MEMBERS` glob is the precedent this mirrors.
  #
  # NAMED BY FILE STEM, capitalized — `governance.bluebook` holds
  # `Hecks.bluebook "Governance"`, the same one-to-one spelling every
  # other chapter in this codebase already keeps between its filename
  # and its declared name.
  module Framework
    ROOT = File.expand_path("../../framework/bluebook", __dir__).freeze

    def self.members
      Dir.glob(File.join(ROOT, "*.bluebook")).to_h do |path|
        [Naming.pascal(File.basename(path, ".bluebook")), path]
      end
    end

    # LOADED FROM ITS OWN REAL PATH, always — never a copy. A domain
    # booted through `Fuzzing::IsolatedBoot`'s tmp-directory copy still
    # reaches the SAME `framework/bluebook/governance.bluebook` this
    # constant points at, because `uses_framework` runs `Kernel.load`
    # against `ROOT`, not against anything inside the copied domain
    # directory — there is nothing here for a relocated copy to break,
    # the way a symlink carried along with the copy would.
    #
    # A framework member's own `.hecksagon` travels with it, the same
    # order `Adapters::Folder::DOMAIN_ORDER` already loads any other
    # domain's own bluebook-then-hecksagon pair in.
    def self.load!(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(', ')}"
      end

      Kernel.load(path)
      hecksagon = path.sub(/\.bluebook\z/, ".hecksagon")
      Kernel.load(hecksagon) if File.exist?(hecksagon)
    end
  end
end
