require_relative "../../../../ports/persistence"
require_relative "../../../../ports/persistence/binding_policy"
require_relative "lineage"
require_relative "../../../../naming"
require_relative "../../../../framework"
require_relative "../../../../chapters"
require_relative "../../../../runtime/registry"
require_relative "expected_era"

module Hecks
  module Runtime
    # The boot-time era gate for lineage-capable adapters (Postgres today):
    # each capable adapter's own era_check! decides hold, recognize, mint, or refuse.
    module EraCheck
      module_function

      # Runs both halves of the era gate over every bluebook in a registry.
      #
      # Looks up each bluebook's own source separately: `uses_framework` can share a boot between
      # the domain's own bluebook and a differently-sourced one, so one file read once and reused
      # for every bluebook would attribute the wrong text.
      #
      # @param registry [Runtime::Registry] the registry being booted
      # @param directory [String] the domain's bluebook directory, searched for each source
      # @return [void]
      # @raise [Runtime::WiringError] if a compute rule is bound to a non-lineage-capable adapter,
      #   a persistence binding cannot be resolved, a lineage-bound bluebook has no findable
      #   source, or `era_check!` refuses the boot
      def check!(registry, directory)
        check_compute_rules_for_registry!(registry)
        check_lineage!(registry, directory)
      end

      # Refuses the boot when any bluebook's compute rule is bound away from Postgres.
      #
      # Runs unconditionally for every registry, unlike check_lineage!'s
      # capability-gated pass below (ADR 0031).
      #
      # @param registry [Runtime::Registry] the registry whose bluebooks are all checked
      # @return [void]
      # @raise [Runtime::WiringError] if an aggregate carrying a compute rule is bound to an
      #   adapter that is not lineage-capable, or its persistence binding cannot be resolved
      def check_compute_rules_for_registry!(registry)
        registry.bluebooks.each_value { |bluebook| check_compute_rules!(registry, bluebook) }
      end

      # Hands every bluebook, with its own source text, to its adapter's era check.
      #
      # Capability-gated (ADR 0031): check_bluebook! below still returns
      # early for any bluebook whose own binding isn't lineage-capable.
      #
      # @param registry [Runtime::Registry] the registry being booted
      # @param directory [String] path of the domain's own bluebook directory
      # @return [void]
      # @raise [Runtime::WiringError] if a persistence binding cannot be resolved, a
      #   lineage-bound bluebook has no findable source, or the adapter's own `era_check!`
      #   refuses the boot
      def check_lineage!(registry, directory)
        registry.bluebooks.each_value do |bluebook|
          check_bluebook!(registry, bluebook, source_text_for(bluebook, directory, registry: registry), directory: directory)
        end
      end

      # Decides whether a registry binds anything that carries eras.
      #
      # Mirrors check_bluebook!'s own per-bluebook anchor check, asked
      # once up front so a registry with nothing lineage-capable never
      # registers the `:era_check` gate at all.
      #
      # @param registry [Runtime::Registry] the registry whose bluebooks are asked
      # @return [Boolean] true when some bluebook's first aggregate is bound to a
      #   lineage-capable adapter; false for an empty registry or one with no such binding
      # @raise [Runtime::WiringError] if a first aggregate's persistence binding is missing,
      #   ambiguous, or carries an unsupported role
      def lineage_capable_registry?(registry)
        registry.bluebooks.each_value.any? do |bluebook|
          first = bluebook.aggregates.first
          next false unless first

          lineage_capable?(registry, adapter_for(registry, bluebook.name, first))
        end
      end

      # Reads the source text one bluebook was declared in, wherever that source lives.
      #
      # Matched by declared name, not position: a domain directory using
      # `uses_framework` may hold more than one file, and a framework
      # member or vendored bluebook is excluded from the single-file
      # fallback so its own real source is read, not a sibling's.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook whose source is wanted
      # @param directory [String] path of the domain's own bluebook directory
      # @param registry [Runtime::Registry, nil] nil skips the vendored-bluebook lookup
      # @return [String, nil] UTF-8 text of every matching file joined with `"\n"`, or nil
      def source_text_for(bluebook, directory, registry: nil)
        domain_files = Dir[File.join(directory, "*.bluebook")]
        own = domain_files.select { |path| declares_bluebook?(path, bluebook.name) }
        own = fallback_source_files(bluebook, directory, domain_files, registry) if own.empty?
        return if own.empty?

        own.map { |path| File.read(path, encoding: "UTF-8") }.join("\n")
      end

      # Scans a file for a `Hecks.bluebook "<name>"` line opening the named bluebook.
      #
      # @param path [String] path of the `.bluebook` file to scan, read as UTF-8
      # @param bluebook_name [String] the declared bluebook name, matched in its `inspect`
      #   (double-quoted) spelling
      # @return [Boolean] true when some line, after leading whitespace, starts with
      #   `Hecks.bluebook` followed by that quoted name
      def declares_bluebook?(path, bluebook_name)
        File.foreach(path, encoding: "UTF-8").any? do |line|
          line.match?(/\A\s*Hecks\.bluebook\s+#{Regexp.escape(bluebook_name.inspect)}/)
        end
      end

      # Picks the files to read for a bluebook no file in the domain directory declares.
      #
      # Tries, in order: a chapter the gem carries (the QA ledger's QualityControl), the domain's
      # own single remaining file, a framework member, then a vendored embryonaut bluebook.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook whose source is wanted
      # @param directory [String] path of the domain's own bluebook directory
      # @param domain_files [Array<String>] paths of every `.bluebook` file in `directory`
      # @param registry [Runtime::Registry, nil] the registry asked for a vendored name; nil
      #   skips the vendored lookup
      # @return [Array<String>] file paths to read, in load order; `[]` when none applies
      def fallback_source_files(bluebook, directory, domain_files, registry)
        vendored_name = registry && vendored_bluebook_name_for(registry, bluebook.name)
        framework_path = Framework.members[bluebook.name]
        attached = Chapters.index.fetch(bluebook.name, [])

        if attached.any? && !framework_path && !vendored_name
          attached
        elsif domain_files.size == 1 && !framework_path && !vendored_name
          domain_files
        elsif framework_path
          [framework_path]
        elsif vendored_name
          vendored_source_for(directory, vendored_name)
        else
          []
        end
      end

      # Recovers the vendored package name behind a bluebook, if some hecksagon vendored it.
      #
      # Matched by Pascal-casing: the vendored name Pascal-cases to this
      # bluebook's own declared name.
      #
      # @param registry [Runtime::Registry] the registry whose hecksagons are searched
      # @param bluebook_name [String] the bluebook's declared Pascal-case name
      # @return [String, nil] the package name as written in `uses_embryonaut_bluebook`; nil
      #   when no hecksagon vendored a package whose name Pascal-cases to `bluebook_name`
      def vendored_bluebook_name_for(registry, bluebook_name)
        registry.hecksagons.each_value do |hecksagon|
          match = hecksagon.vendored_bluebooks.find { |name| Naming.pascal(name) == bluebook_name }
          return match if match
        end
        nil
      end

      # Lists the `.bluebook` files a vendored embryonaut package ships.
      #
      # Listed in `Dir.glob` order, matching load order at boot, since a
      # later reconstruction of this text depends on seeing files in the
      # order that built the live shape.
      #
      # @param directory [String] path of the domain's own bluebook directory, whose parent
      #   holds `vendor/embryonaut_bluebooks`
      # @param name [String] the vendored package name, as `vendored_bluebook_name_for`
      #   returns it
      # @return [Array<String>] paths of the package's `.bluebook` files in `Dir.glob` order;
      #   `[]` when the package directory is missing or empty
      def vendored_source_for(directory, name)
        dir = File.join(File.dirname(directory), "vendor", "embryonaut_bluebooks", name, "bluebook")
        Dir.glob(File.join(dir, "*.bluebook"))
      end

      # Hands one bluebook to its adapter's `era_check!`, when that adapter carries eras.
      #
      # The first aggregate is the anchor: its binding alone decides the adapter asked.
      #
      # @param registry [Runtime::Registry] the registry being booted
      # @param bluebook [Bluebook::Chapter] the bluebook to check
      # @param current_text [String, nil] the bluebook's source; nil means none was found
      # @param directory [String, nil] the domain's bluebook directory, named in the refusal
      # @return [void]
      # @raise [Runtime::WiringError] if the first aggregate's binding cannot be resolved,
      #   `current_text` is nil for a lineage-bound bluebook, or the adapter's `era_check!`
      #   refuses the boot
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

        settings = registry.binding_settings(bluebook.name, Ports::Persistence::VERB, adapter_name)
        registry.adapter_class(adapter_name).era_check!(
          registry: registry, bluebook: bluebook, current_text: current_text, settings: settings,
          directory: directory
        )
      end

      # Refuses the boot when one bluebook's compute rule is bound away from Postgres.
      #
      # A compute rule's SQL is its only implementation, so it cannot
      # boot on any adapter but Postgres, independent of shape checks.
      #
      # @param registry [Runtime::Registry] the registry holding the declared translations
      #   and the aggregate's bindings
      # @param bluebook [Bluebook::Chapter] the bluebook whose aggregates are checked
      # @return [void]
      # @raise [Runtime::WiringError] if an aggregate carrying a compute rule is bound to an
      #   adapter that is not lineage-capable, or its persistence binding cannot be resolved
      def check_compute_rules!(registry, bluebook)
        bluebook.aggregates.each do |aggregate|
          lineage = Ports::Persistence::Lineage.for(registry, bluebook.name, aggregate)
          next unless lineage&.computes?

          adapter = adapter_for(registry, bluebook.name, aggregate)
          next if lineage_capable?(registry, adapter)

          raise WiringError, "compute rules require the Postgres adapter; #{aggregate.name} is bound to #{adapter}"
        end
      end

      # Names the adapter an aggregate's authoritative persistence bind points at.
      #
      # @param registry [Runtime::Registry] the registry holding the domain's hecksagon
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate whose binding is resolved
      # @return [String] the bound adapter's name, such as `"PostgresEra"`; `"Memory"` when
      #   the domain declares no hecksagon
      # @raise [Runtime::WiringError] if the aggregate has no persistence bind, more than one
      #   authoritative bind, or a bind with a role the port does not support
      def adapter_for(registry, domain, aggregate)
        Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate).adapter
      end

      # Asks a named adapter whether it carries eras.
      #
      # Postgres alone answers true today; the seam lets a second
      # lineage-capable adapter arrive without touching this file.
      #
      # @param registry [Runtime::Registry] the registry whose `adapters` must list the name
      # @param adapter_name [String] the adapter's name, as `adapter_for` returns it
      # @return [Boolean] the adapter's own answer; false if unlisted, not lineage-capable, or
      #   any `StandardError` is raised
      def lineage_capable?(registry, adapter_name)
        adapter_class = registry.adapters[adapter_name] && registry.adapter_class(adapter_name)
        adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
      rescue StandardError
        false
      end
    end
  end
end
