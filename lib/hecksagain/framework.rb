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
    # ONLY THE BLUEBOOK — a framework member's own `.hecksagon`, if it
    # has one, is NOT auto-loaded. Persistence is a WIRING decision, the
    # same as any other aggregate's, and belongs to whoever is doing the
    # deploying, not to a default baked into the framework member
    # itself: a consuming app needs `Governance::RoleAssignment` durable
    # (Postgres, say), and a framework member hard-coding Memory for its
    # own specs would silently make that decision FOR every app that
    # attaches it. The consuming app declares its OWN, SEPARATE
    # `Hecks.hecksagon "Governance" do ... end` block for that — not
    # binds folded into its own hecksagon, which would build but never
    # resolve: `Ports::Persistence::BindingPolicy.resolve` looks up
    # `registry.hecksagon` by the AGGREGATE's own domain name, not the
    # domain doing the binding, the one invariant this runtime holds
    # everywhere else too. See `examples/banking/bluebook/banking.hecksagon`
    # for the pattern — a real `.hecksagon` file can hold more than one
    # `Hecks.hecksagon` call, one per domain it wires.
    def self.load!(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(', ')}"
      end

      Kernel.load(path)
    end
  end
end
