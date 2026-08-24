require_relative "runtime/registry"

module Hecks
  # THE REGISTRY OF FRAMEWORK BLUEBOOKS — Governance, Identity, and
  # whatever lands beside them in `lib/hecks/framework/bluebook/`:
  # domain-agnostic chapters no single example owns, shared by reference
  # rather than copied into every domain that wants one.
  #
  # UNDER `lib/`, not a top-level sibling — a real consumer (embryonaut)
  # vendors ONLY `lib/` (`bin/vendor-hecks`, and this gem's own
  # `hecks.gemspec`, both glob `lib/**/*`), so a `framework/`
  # sitting beside `lib/` rather than inside it packaged and vendored
  # cleanly but left `uses_framework` finding nothing at runtime —
  # `Framework::ROOT` pointed at a directory that simply never shipped.
  # Nothing in THIS repo's own suite caught it, since every spec here
  # reads the working tree directly; only vendoring into a real consumer
  # did. Same reasoning `lib/hecks/language/bluebook/` already
  # settled for the self-hosted grammar's own `.bluebook` files —
  # non-Ruby data a module owns lives inside `lib/` with the code that
  # reads it, not beside it.
  #
  # DERIVED FROM THE DIRECTORY, not hand-listed a second time — the same
  # reasoning `Assembly::CONTRACTS` gives for reading the language's own
  # fields from a table instead of restating them: a member added here
  # and forgotten in a list would be a member `uses_framework` could
  # never find, and a hand-kept list is exactly the shape that goes
  # stale in silence. `spec/corpus_spec.rb`'s own `FRAMEWORK_MEMBERS`
  # glob is the precedent this mirrors.
  #
  # NAMED BY FILE STEM, capitalized — `governance.bluebook` holds
  # `Hecks.bluebook "Governance"`, the same one-to-one spelling every
  # other chapter in this codebase already keeps between its filename
  # and its declared name.
  module Framework
    ROOT = File.expand_path("framework/bluebook", __dir__).freeze

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
    # IDEMPOTENT, PER REGISTRY — `uses_framework` is now called more than
    # once for the SAME member within a single boot (S8: a domain
    # attaching Governance for its own role check, plus a framework
    # sibling attaching it too, e.g. `banking.hecksagon`'s Identity
    # block). `Kernel.load` always re-executes the file, unlike
    # `require`, so a second call would re-run `Hecks.bluebook
    # "Governance"` a second time — and the self-hosting meta-domain
    # records every declaration as a real dispatched command against its
    # own ledger, so a second `Declare` for the SAME aggregate is a real
    # `AlreadyExists`, not a no-op. Skipped once the member's bluebook is
    # already registered in THIS registry — the same chapter, not merely
    # a same-named one from a stale prior boot.
    def self.load!(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(', ')}"
      end

      return if Hecks.current_registry.bluebook(name.to_s)

      Kernel.load(path)
    end
  end
end
