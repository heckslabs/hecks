require_relative "../../../../ports/persistence"
require_relative "../../../../ports/persistence/binding_policy"
require_relative "lineage"
require_relative "../../../../naming"
require_relative "../../../../framework"
require_relative "../../../../runtime/registry"

module Hecks
  module Runtime
    # The boot-time era gate, run for the adapters that have eras — the
    # lineage-capable ones. An era is a fact about stored data that some
    # adapter can carry across a shape change; an adapter that cannot
    # translate has no era to hold, and holding one for it would record
    # history about data nothing can act on.
    #
    # The whole domain is handed to the capable adapter's own era check
    # (Postgres: hold, recognize, mint, or refuse toward the scaffold),
    # which keeps its era facts as rows beside its data. That
    # co-location is load-bearing — a watermark only means something
    # against the journal it was cut from, and an approval recorded
    # anywhere but the reviewed database binds to nothing.
    #
    # The capability is asked of the adapter, never of its name: a
    # second adapter that grows an era story declares lineage_capable?
    # and era_check! and needs no change here.
    #
    # Detection and identity are separate jobs: this check never hashes
    # anything — era names come from the store, already minted (by the
    # scaffold) or absent. Refusal wordings are contract, pinned by the
    # corpus.
    module EraCheck
      module_function

      # Each bluebook's own source, not one file read once and reused
      # for every bluebook in the registry — true as long as a domain
      # directory only ever held exactly one, and silently wrong the
      # moment `uses_framework` made a second, differently-sourced
      # bluebook (Governance, Identity — `lib/hecks/framework/bluebook/`,
      # not the domain's own directory) share a boot with the first.
      # Caught the hard way: three domains booted together, one real
      # source text (the domain's own), and every other domain's era-1
      # held that text under its own name — a shadow-parse of it later
      # reconstructs a completely different shape, and every boot after
      # the first refuses toward a scaffold that was never the real
      # drift.
      def check!(registry, directory)
        check_compute_rules_for_registry!(registry)
        check_lineage!(registry, directory)
      end

      # The domain-agnostic half, split out for ADR 0031's boot-gate
      # registry: a compute rule requires Postgres whatever adapter is
      # actually bound, so this must run for every registry, the same way
      # `registry.verify!` does — it is not conditional on any adapter
      # being lineage-capable, and must never be skipped by
      # `check_lineage!`'s own capability gate below.
      def check_compute_rules_for_registry!(registry)
        registry.bluebooks.each_value { |bluebook| check_compute_rules!(registry, bluebook) }
      end

      # The capability-gated half — ADR 0031's registered `:era_check`
      # gate. Registration is conditional on `lineage_capable_registry?`;
      # `check_bluebook!` below still carries its own per-bluebook
      # `lineage_capable?` return-early, unchanged, for a registry with a
      # mix of lineage-capable and plain-adapter bluebooks.
      def check_lineage!(registry, directory)
        registry.bluebooks.each_value do |bluebook|
          check_bluebook!(registry, bluebook, source_text_for(bluebook, directory, registry: registry), directory: directory)
        end
      end

      # The `:era_check` gate's own registration predicate: true iff at
      # least one bluebook's own anchor (first) aggregate resolves to a
      # lineage-capable adapter — mirrors `check_bluebook!`'s existing
      # per-bluebook anchor check, just asked once, up front, of the
      # whole registry, so a registry with nothing lineage-capable bound
      # anywhere never registers the gate at all.
      def lineage_capable_registry?(registry)
        registry.bluebooks.each_value.any? do |bluebook|
          first = bluebook.aggregates.first
          next false unless first

          lineage_capable?(registry, adapter_for(registry, bluebook.name, first))
        end
      end

      # The domain's own directory first, matched by name — a real app's
      # directory may hold more than one file once `uses_framework`
      # exists, so ".first" alone can no longer be trusted, the exact
      # way it silently wasn't the day this was found: three domains
      # booted together, one real source text read once (the domain's
      # own, ".first"'d), and every other domain's era-1 held that text
      # under its own name — a later shadow-parse of it reconstructs a
      # completely different shape, and every boot after the first
      # refuses toward a scaffold that was never the real drift.
      #
      # A single-file directory whose one file names something else
      # falls back to it anyway (a fixture may legitimately name its
      # file differently from the `Hecks.bluebook` it declares) — unless
      # this bluebook is a known framework member or a vendored
      # embryonaut bluebook (see `vendored_source_for` below), in which
      # case that one file is certainly some other domain's, not this
      # one's, and the real registry is asked instead — the only other
      # two places a bluebook in this registry could have come from, per
      # `uses_framework` and `uses_embryonaut_bluebook`.
      #
      # **The bug this guards against, found live**: `Framework.members` was
      # the only exclusion checked here, so a domain attaching a
      # vendored bluebook instead (`uses_embryonaut_bluebook`, which has
      # no equivalent registry — see embryonaut_bluebook.rb's own
      # header) fell straight through the single-file fallback: a
      # directory holding exactly one `.bluebook` file (the target
      # domain's own) handed that same text back for the vendored
      # bluebook's era check too. PostgresEra minted era 1 for the
      # vendored domain with the target's own source stamped as its
      # `held_text` — the label computed from it, too — so the very
      # next boot re-derived the vendored domain's real shape, found it
      # didn't match what got (wrongly) stored, and refused to boot
      # toward a scaffold for drift that never actually happened.
      # `registry:` is what lets this check the one thing
      # `Framework.members` cannot: whether some hecksagon in this
      # registry declared `uses_embryonaut_bluebook` for this exact
      # bluebook name, the same way `EmbryonautBluebook.load!` itself
      # already resolves the vendored package's own directory.
      def source_text_for(bluebook, directory, registry: nil)
        domain_files = Dir[File.join(directory, "*.bluebook")]
        own = domain_files.select { |path| declares_bluebook?(path, bluebook.name) }
        own = fallback_source_files(bluebook, directory, domain_files, registry) if own.empty?
        return if own.empty?

        own.map { |path| File.read(path, encoding: "UTF-8") }.join("\n")
      end

      def declares_bluebook?(path, bluebook_name)
        File.foreach(path, encoding: "UTF-8").any? do |line|
          line.match?(/\A\s*Hecks\.bluebook\s+#{Regexp.escape(bluebook_name.inspect)}/)
        end
      end

      # Only reached once nothing in the domain's own directory actually
      # declares this bluebook by name. Three remaining sources, in
      # order: a genuinely single-file domain directory whose one file
      # just happens to name something else (but only when this
      # bluebook isn't already known to come from somewhere else
      # entirely — the exact guard the bug below was missing half of);
      # a framework member; a vendored embryonaut bluebook.
      def fallback_source_files(bluebook, directory, domain_files, registry)
        vendored_name = registry && vendored_bluebook_name_for(registry, bluebook.name)
        framework_path = Framework.members[bluebook.name]

        if domain_files.size == 1 && !framework_path && !vendored_name
          domain_files
        elsif framework_path
          [framework_path]
        elsif vendored_name
          vendored_source_for(directory, vendored_name)
        else
          []
        end
      end

      # **The name `uses_embryonaut_bluebook` was actually called with** —
      # recovered from whichever hecksagon in this registry recorded it
      # (`HecksagonBuilder#uses_embryonaut_bluebook`'s own
      # `@vendored_bluebooks`), matched the same way
      # `EmbryonautBluebook.load!` itself decides idempotency: the
      # vendored name Pascal-cases to this bluebook's own declared name.
      # Nil for an ordinary bluebook nothing ever vendored.
      def vendored_bluebook_name_for(registry, bluebook_name)
        registry.hecksagons.each_value do |hecksagon|
          match = hecksagon.vendored_bluebooks.find { |name| Naming.pascal(name) == bluebook_name }
          return match if match
        end
        nil
      end

      # **The same path `EmbryonautBluebook.load!` itself resolves from** —
      # `<registry.root>/vendor/embryonaut_bluebooks/<name>/bluebook/`,
      # rebuilt here from `directory` (the domain's own bluebook
      # directory, always `registry.root`'s immediate child — see
      # `Runtime::Loader.boot`) rather than threading `registry.root`
      # through as a second parameter. Every `.bluebook` file the
      # package ships, in the same `Dir.glob` order actually loaded at
      # boot time — order matters here because this text is later
      # re-parsed whole (`EraCheck::shadow`) to reconstruct the shape a
      # held era claims, and that reconstruction must see the files in
      # the order that actually built the live shape.
      def vendored_source_for(directory, name)
        dir = File.join(File.dirname(directory), "vendor", "embryonaut_bluebooks", name, "bluebook")
        Dir.glob(File.join(dir, "*.bluebook"))
      end

      def check_bluebook!(registry, bluebook, current_text, directory: nil)
        first = bluebook.aggregates.first
        return unless first

        adapter_name = adapter_for(registry, bluebook.name, first)
        return unless lineage_capable?(registry, adapter_name)

        unless current_text
          raise WiringError,
                "cannot boot #{bluebook.name}: bound to a lineage-capable adapter, but no source file for " \
                "it could be found (checked #{directory.inspect} and the framework registry)"
        end

        settings = registry.world(bluebook.name)&.for_binding(Ports::Persistence::VERB, adapter_name) || {}
        registry.adapter_class(adapter_name).era_check!(
          registry: registry, bluebook: bluebook, current_text: current_text, settings: settings,
          directory: directory
        )
      end

      # The per-rule capability gate — not an era fact, and so it
      # survives on every adapter: a compute rule's SQL is its only
      # implementation, so an aggregate carrying one cannot boot
      # anywhere but Postgres, whatever any shape comparison would say.
      def check_compute_rules!(registry, bluebook)
        bluebook.aggregates.each do |aggregate|
          lineage = Ports::Persistence::Lineage.for(registry, bluebook.name, aggregate)
          next unless lineage&.computes?

          adapter = adapter_for(registry, bluebook.name, aggregate)
          next if lineage_capable?(registry, adapter)

          raise WiringError, "compute rules require the Postgres adapter; #{aggregate.name} is bound to #{adapter}"
        end
      end

      def adapter_for(registry, domain, aggregate)
        Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate).adapter
      end

      # The capability idiom: an adapter class that answers
      # lineage_capable? with true carries eras and may act on drift
      # (translate, fork, merge). Postgres alone does today; the seam is
      # what lets a second one arrive without touching this file.
      def lineage_capable?(registry, adapter_name)
        adapter_class = registry.adapters[adapter_name] && registry.adapter_class(adapter_name)
        adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
      rescue StandardError
        false
      end
    end
  end
end
