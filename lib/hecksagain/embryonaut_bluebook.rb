module Hecksagain
  # A VENDORED, EXTERNAL BLUEBOOK — same shape as Framework (framework.rb),
  # for members that don't ship inside hecksagain's own lib/ at all: a
  # separate, independently-versioned package
  # (github.com/chrisyoung/embryonaut_bluebooks) that a consuming project
  # vendors into its OWN checkout, the same way a project already vendors
  # hecksagain itself (bin/vendor_hecksagain, vendor/hecksagain/).
  #
  # RECOVERED, NOT REBUILT — this module and its `uses_embryonaut_bluebook`
  # DSL word (hecksagon_builder.rb) were built on a prior commit of this
  # repo (933d1dd), vendored out to a real consumer (lifeadelics/domain,
  # for embryonaut_bluebooks/payments), and then lost from this repo's own
  # reachable history — a hard reset or rebase left no branch containing
  # that commit. The lifeadelics vendor snapshot (a `git archive` of that
  # commit, committed into their repo) was the only surviving copy; this
  # file is ported forward from it, checked against current `main`'s own
  # conventions rather than copied wholesale, since the two trees had
  # otherwise diverged for weeks in both directions.
  #
  # RESOLVED FROM THE CONSUMING REGISTRY'S OWN ROOT, not this gem's
  # __dir__ — Framework::ROOT can be a fixed, `__dir__`-relative constant
  # because framework members ship inside this gem; an embryonaut bluebook
  # ships inside the CONSUMER's own checkout instead, at
  # `<registry.root>/vendor/embryonaut_bluebooks/<name>/bluebook/`. There
  # is no fixed answer until a registry (and its root) actually exists, so
  # this resolves lazily, per call — the same reason `uses_framework`
  # itself only runs at hecksagon-build time, when a real registry is
  # current.
  #
  # EVERY `.bluebook` FILE IN THE PACKAGE, SORTED — not just one. Unlike a
  # framework member (one file, named by its own stem), a vendored package
  # can span several bluebook files that reopen the SAME `Hecks.bluebook`
  # (embryonaut_bluebooks/payments/bluebook/{payment,payments,policies}
  # .bluebook all reopen "Payments"). Load order matters — policies
  # .bluebook names `Payment::Succeed` and needs the aggregate already
  # built — and a plain alphabetical sort already gives the right order:
  # payment < payments < policies, the same reason that package's own
  # files are named to fall in that order in the first place.
  #
  # ONLY THE BLUEBOOK FILES — same restriction Framework draws, same
  # reason: a `.hecksagon`/`.port`/`.adapter` is a WIRING decision
  # (persistence, which processor adapter is bound) that belongs to
  # whoever is deploying, never baked into the vendored package itself.
  # embryonaut_bluebooks/payments ships its own mock `.hecksagon` for its
  # own spec suite; a consumer declares its OWN separate
  # `Hecks.hecksagon "Payments" do ... end` to bind real storage/adapters
  # — see Framework's own comment for the fuller reasoning, identical here.
  #
  # IDEMPOTENT THE SAME WAY Framework.load! IS — checked against the
  # bluebook this package actually declares (`Naming.pascal("payments")`
  # => "Payments"), not a separate ledger. A vendored package's directory
  # name and its declared `Hecks.bluebook` name are the one convention
  # this reuses from Framework rather than reinventing.
  module EmbryonautBluebook
    def self.load!(name, registry: Hecksagain.current_registry)
      unless registry&.root
        raise Runtime::WiringError,
              "uses_embryonaut_bluebook(#{name.inspect}) needs a registry with a root to vendor from"
      end

      return if registry.bluebook(Naming.pascal(name.to_s))

      dir   = File.join(registry.root, "vendor", "embryonaut_bluebooks", name.to_s, "bluebook")
      files = Dir.glob(File.join(dir, "*.bluebook"))

      if files.empty?
        raise Runtime::WiringError,
              "no vendored embryonaut bluebook named #{name.inspect} at #{dir} — " \
              "run bin/vendor_embryonaut_bluebooks #{name}"
      end

      files.each { |file| Kernel.load(file) }
    end
  end
end
