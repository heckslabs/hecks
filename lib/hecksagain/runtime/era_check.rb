require_relative "../ports/persistence"
require_relative "../ports/persistence/binding_policy"
require_relative "../ports/persistence/lineage"
require_relative "registry"

module Hecksagain
  module Runtime
    # The boot-time era gate, run for the adapters that HAVE eras — the
    # lineage-capable ones. An era is a fact about stored data that some
    # adapter can carry across a shape change; an adapter that cannot
    # translate has no era to hold, and holding one for it would record
    # history about data nothing can act on.
    #
    # The whole domain is handed to the capable adapter's own era check
    # (Postgres: hold, recognize, mint, or refuse toward the scaffold),
    # which keeps its era facts as rows BESIDE its data. That
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

      def check!(registry, directory)
        source_path = Dir[File.join(directory, "*.bluebook")].first
        return unless source_path

        current_text = File.read(source_path)
        registry.bluebooks.each_value { |bluebook| check_bluebook!(registry, bluebook, current_text, directory: directory) }
      end

      def check_bluebook!(registry, bluebook, current_text, directory: nil)
        check_compute_rules!(registry, bluebook)

        first = bluebook.aggregates.first
        return unless first

        adapter_name = adapter_for(registry, bluebook.name, first)
        return unless lineage_capable?(registry, adapter_name)

        settings = registry.world(bluebook.name)&.for_binding(Ports::Persistence::VERB, adapter_name) || {}
        registry.adapter_class(adapter_name).era_check!(
          registry: registry, bluebook: bluebook, current_text: current_text, settings: settings,
          directory: directory
        )
      end

      # The per-rule capability gate — NOT an era fact, and so it
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

      # The capability idiom: an adapter CLASS that answers
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
