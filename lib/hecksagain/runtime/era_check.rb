module Hecksagain
  module Runtime
    # The boot-time era gate, run for EVERY adapter: hold the bluebook
    # source at the first boot of an era, compare the current text's
    # storage-shape projection against the held eras structurally on
    # every boot after that, and refuse loudly the moment the shape has
    # drifted under an adapter that cannot act on drift. Only Postgres
    # declares the lineage capability; everywhere else the remedy is
    # named in the refusal, not guessed at later inside a broken INSERT.
    #
    # Detection and identity are separate jobs: this check never hashes
    # anything — era names come from the store, already minted (by the
    # Ruby scaffold) or absent. Wordings are byte-identical with
    # rust/src/runtime/era_check.rs.
    module EraCheck
      module_function

      NamedOnly = Struct.new(:name) do
        # BindingPolicy addresses constructs by hecks_name; this shim
        # carries only the name, so they are the same thing here.
        alias_method :hecks_name, :name
      end

      def check!(registry, directory)
        source_path = Dir[File.join(directory, "*.bluebook")].first
        return unless source_path

        current_text = File.read(source_path)
        registry.bluebooks.each_value { |bluebook| check_bluebook!(registry, bluebook, current_text, directory: directory) }
      end

      def check_bluebook!(registry, bluebook, current_text, directory: nil)
        check_compute_rules!(registry, bluebook)

        # A lineage-capable adapter holds its era facts as ROWS beside
        # its data, not files — and it can ACT on drift. The gate hands
        # the whole domain to the adapter's own era check (Postgres:
        # hold, recognize, mint, or refuse toward the scaffold).
        first = bluebook.aggregates.first
        if first
          adapter_name = adapter_for(registry, bluebook.name, first)
          settings = registry.world(bluebook.name)&.for_binding(Ports::Persistence::VERB, adapter_name) || {}
          ephemeral = (settings[:eras] || settings["eras"]).to_s == "ephemeral"
          if lineage_capable?(registry, adapter_name)
            if ephemeral
              raise WiringError,
                    "#{bluebook.name} binds Postgres with eras \"ephemeral\" — the enforcement-grade adapter " \
                    "never forgets an era; drop the setting, or bind a file adapter for iteration"
            end
            adapter_class = registry.adapter_class(adapter_name)
            return adapter_class.era_check!(
              registry: registry, bluebook: bluebook, current_text: current_text, settings: settings,
              directory: directory
            )
          end
          # A DECLARED-ephemeral domain iterates freely: no held texts,
          # no drift refusals — the world file says, in versioned text,
          # that this data is disposable. The compute gate above still
          # applies; nothing else does.
          return if ephemeral
        end

        store = Ports::Persistence::EraStore.new(registry.root, bluebook.name)
        held = store.held_texts
        return store.hold_first!(current_text, projection: StorageShape.project(bluebook)) if held.empty?

        current_shape = StorageShape.project(bluebook)
        shapes = held.map do |ordinal, text|
          [ordinal, StorageShape.project(EraGuard.shadow_parse(text, store.held_path(ordinal)))]
        end

        latest_ordinal, latest_shape = shapes.last
        return if latest_shape == current_shape

        matched = shapes.find { |_, shape| shape == current_shape }&.first
        refuse!(registry, bluebook, current_shape, latest_shape,
                store: store, matched: matched, latest: latest_ordinal)
      end

      # The per-rule capability gate, checked before the general drift
      # machinery says anything vaguer: a compute rule's SQL is its only
      # implementation, so an aggregate carrying one cannot boot anywhere
      # but Postgres — even before any shape comparison happens.
      def check_compute_rules!(registry, bluebook)
        bluebook.aggregates.each do |aggregate|
          lineage = Ports::Persistence::Lineage.for(registry, bluebook.name, aggregate)
          next unless lineage&.computes?

          adapter = adapter_for(registry, bluebook.name, aggregate)
          next if lineage_capable?(registry, adapter)

          raise WiringError, "compute rules require the Postgres adapter; #{aggregate.name} is bound to #{adapter}"
        end
      end

      def refuse!(registry, bluebook, current_shape, latest_shape, store:, matched:, latest:)
        subject = drifted_subject(bluebook, current_shape, latest_shape)
        adapter = adapter_for(registry, bluebook.name, NamedOnly.new(subject))
        return if lineage_capable?(registry, adapter)

        if matched
          raise WiringError,
                "cannot boot #{subject}: this is era #{matched}'s shape, which era #{latest} superseded, " \
                "and #{adapter} cannot serve a superseded era — bind Postgres, or reset the data"
        end

        era = latest + 1
        named = store.label_for(era)
        raise WiringError,
              "cannot boot #{subject}: the shape changed (era #{era}#{named ? ", #{named}" : ''}) " \
              "and #{adapter} cannot translate — bind Postgres, or reset the data"
      end

      # The refusal names the first place the shape actually moved: the
      # first current aggregate (declaration order) whose projection
      # differs from its held counterpart — or, when only a vanished
      # aggregate distinguishes the two eras, the vanished one, since it
      # is its data that stands to be stranded.
      def drifted_subject(bluebook, current_shape, latest_shape)
        held_by_name = (latest_shape["aggregates"] || []).to_h { |aggregate| [aggregate["name"], aggregate] }
        current_by_name = (current_shape["aggregates"] || []).to_h { |aggregate| [aggregate["name"], aggregate] }

        drifted = bluebook.aggregates.map(&:name).find do |name|
          held_by_name[name] != current_by_name[name]
        end
        drifted || (held_by_name.keys - current_by_name.keys).first || bluebook.name
      end

      def adapter_for(registry, domain, aggregate)
        Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate).adapter
      end

      # The capability idiom: an adapter CLASS that answers
      # lineage_capable? with true may act on drift (translate, fork,
      # merge). Postgres alone will; everything else refuses above.
      def lineage_capable?(registry, adapter_name)
        adapter_class = registry.adapters[adapter_name] && registry.adapter_class(adapter_name)
        adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
      rescue StandardError
        false
      end
    end
  end
end
