require "fileutils"
require_relative "era_guard/shape_diff"
require_relative "../bluebook/meta_validator"
require_relative "../naming"
require_relative "../ports/loading"
require_relative "../ports/persistence/lineage"
require_relative "registry"

module Hecksagain
  module Runtime
    # Detects when a bluebook's storage shape has drifted from what its data
    # was written under — a rename or restructure with nothing to explain
    # it. Refuses at boot, before a command can run into the gap and raise
    # something that only makes sense once you already suspect a rename.
    #
    # The held source is a snapshot of the bluebook text as it stood the
    # last time its shape was accepted. It updates only when a drift is
    # seen AND covered by a translation — never on every boot, and never
    # silently when a rename has nothing to explain it.
    module EraGuard
      extend ShapeDiff

      module_function

      def check!(registry, directory)
        registry.bluebooks.each_value { |bluebook| check_bluebook!(registry, bluebook, directory) }
      end

      def check_bluebook!(registry, bluebook, directory)
        source_path = Dir[File.join(directory, "*.bluebook")].first
        return unless source_path

        era_dir   = File.join(registry.root, "data", "eras")
        held_path = File.join(era_dir, "#{Naming.snake(bluebook.name)}.bluebook")
        current_text = File.read(source_path)

        FileUtils.mkdir_p(era_dir)
        unless File.exist?(held_path)
          File.write(held_path, current_text)
          return
        end

        held_bluebook = shadow_parse(File.read(held_path), held_path)
        drifted = false

        bluebook.aggregates.each do |aggregate|
          lineage = Ports::Persistence::Lineage.for(registry, bluebook.name, aggregate)
          held_aggregate = held_bluebook.aggregate(lineage&.ancestor_name || aggregate.name)
          next unless held_aggregate
          next if shape(aggregate) == shape(held_aggregate)

          drifted = true
          uncovered = uncovered_attributes(aggregate, held_aggregate, lineage)
          refuse_uncovered!(bluebook, aggregate, uncovered) unless uncovered.empty?

          unsafe = unsafe_additions(aggregate, held_aggregate, lineage)
          refuse_unsafe_addition!(bluebook, aggregate, unsafe) unless unsafe.empty?
        end

        check_vanished_aggregates!(registry, bluebook, held_bluebook)
        File.write(held_path, current_text) if drifted
      end

      # An aggregate that existed in the held text and answers to no
      # current name — renamed silently, with nothing declaring `was:` to
      # explain where its data went — is exactly the disease this guards
      # against, and a plain per-aggregate diff would never see it: the
      # current aggregate simply has no held counterpart to compare to.
      def check_vanished_aggregates!(registry, bluebook, held_bluebook)
        held_bluebook.aggregates.each do |held_aggregate|
          claimed = bluebook.aggregates.any? do |aggregate|
            aggregate.name == held_aggregate.name ||
              registry.translations.any? do |translation|
                translation.domain == bluebook.name &&
                  translation.for_aggregate(aggregate.name)&.was == held_aggregate.name
              end
          end
          claimed ||= registry.translations.any? do |translation|
            translation.domain == bluebook.name && translation.retired.include?(held_aggregate.name)
          end
          next if claimed

          raise WiringError,
                "cannot boot #{bluebook.name}: #{held_aggregate.name} existed and now doesn't, " \
                "and nothing declares was: #{held_aggregate.name.inspect} to explain where its data went."
        end
      end

      # The Layer-1 coverage refusal — one wording, whoever detects the
      # gap (the file-store boot check here, or Postgres's mint path).
      def refuse_uncovered!(bluebook, aggregate, uncovered)
        raise WiringError,
              "cannot boot #{bluebook.name}::#{aggregate.name}: its shape changed and " \
              "#{uncovered.map { |path| render_path(path) }.join(', ')} #{uncovered.size == 1 ? 'is' : 'are'} not " \
              "explained by any rename, move, convert, retype, or drop. Update bluebook/translations/*.bluebook, e.g. " \
              "#{suggestion(uncovered.first)}."
      end

      # The addition-side sibling of refuse_uncovered! above — same
      # wording shape, different cause: nothing vanished or changed type,
      # something new arrived that an existing record has no way to hold.
      def refuse_unsafe_addition!(bluebook, aggregate, unsafe)
        raise WiringError,
              "cannot boot #{bluebook.name}::#{aggregate.name}: #{unsafe.map { |name| ":#{name}" }.join(', ')} " \
              "#{unsafe.size == 1 ? 'is new and required' : 'are new and required'}, with no default: to fill " \
              "an existing record and no translation explaining what one should read there. Give it a " \
              "default:, make it optional: true or list_of, or declare bluebook/translations/*.bluebook, e.g. " \
              "`backfill :#{unsafe.first}, default: ...`."
      end

      def render_path(path) = path.include?(".") ? path.inspect : ":#{path}"

      def suggestion(path)
        if path.include?(".")
          "`move #{path.inspect}, to: #{path.inspect}` or `drop #{path.inspect}`"
        else
          "`rename :#{path}, to: :new_name` or `drop :#{path}`"
        end
      end

      # Parses held source into its own IR, in a scratch registry so a past
      # era's text never touches the one actually booting.
      #
      # `MetaValidator.while_shadow_parsing` (ADR 0025, docs/dsl-work-
      # slices.md's S0a) is what makes this a LEGACY grammar rather than
      # just a second copy of today's: it stops `BluebookBuilder.build`
      # from judging this text against the grammar as it stands NOW,
      # which is the one thing that would make a removed spelling refuse
      # HISTORY the day it is removed from live source. The scratch
      # registry is throwaway either way — nothing here is dispatched
      # against or exposed to the real one — so skipping the judge/
      # assemble round-trip changes nothing this method reads: `shape`,
      # `uncovered_attributes`, and friends only ever ask the built IR
      # for its own structure.
      def shadow_parse(source, path)
        scratch = Registry.new
        loading = Ports::Loading.bootstrap
        Hecksagain::Bluebook::MetaValidator.while_shadow_parsing do
          Hecksagain.with_registry(scratch) do
            loading.load_library
            Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
          end
        end
        scratch.bluebooks.values.first
      end
    end
  end
end
