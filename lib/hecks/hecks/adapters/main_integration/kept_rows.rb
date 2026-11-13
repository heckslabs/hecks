# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The `KeptAggregate` rows of the Hecks bluebook's `LocalOverlay` aggregate: the aggregates
      # the development pipeline reads back in a later process, each with the copy that needs it.
      # They are read from the booted IR, as `StallWatching` reads its `StallKind` rows, so the
      # overlay writers, the write guard and the saga warning all answer from one declaration.
      module KeptRows
        # The aggregate that holds the rows, and the value object they are members of.
        OWNER = "LocalOverlay"
        # The value object whose members are the rows.
        SHAPE = "KeptAggregate"
        # The copies a row may name; `both` is either.
        COPIES = %w[main train].freeze
        # Where the push train's copy is, the one checkout that is the `train` copy.
        TRAIN_ROOT = File.join(Dir.home, ".claude", "hecks-train")

        module_function

        # @param aggregate [Bluebook::Aggregate, nil] the `LocalOverlay` aggregate's IR
        # @return [Array<Hash{Symbol => String}>] `domain`, `aggregate`, `checkout` and `reason` of
        #   each row; none when the aggregate is absent
        def of(aggregate)
          shape = aggregate&.value_objects&.find { |object| object.hecks_name == SHAPE }
          Array(shape&.members).map { |row| row.to_h.transform_keys(&:to_sym) }
        end

        # @param registry [Runtime::Registry, nil] a booted registry holding the Hecks bluebook
        # @return [Array<Hash{Symbol => String}>] the rows; none when the registry is absent
        def from_registry(registry)
          bluebook = registry&.bluebook("Hecks")
          of(bluebook&.aggregates&.find { |candidate| candidate.hecks_name == OWNER })
        end

        # @param rows [Array<Hash>] the rows
        # @param copy [String] `main` or `train`
        # @return [Array<Hash>] the rows that copy keeps
        def for_copy(rows, copy)
          rows.select { |row| [copy, "both"].include?(row[:checkout].to_s) }
        end

        # @param rows [Array<Hash>] the rows
        # @param domain [String] a bluebook's name
        # @param aggregate [String, nil] an aggregate's name
        # @return [Hash, nil] the row naming that aggregate
        def find(rows, domain, aggregate)
          rows.find { |row| row[:domain] == domain.to_s && row[:aggregate] == aggregate.to_s }
        end

        # @param root [String] a checkout's root
        # @return [String] `train` for the push train's copy, else `main`
        def copy_of(root, train_root: TRAIN_ROOT)
          File.expand_path(root) == File.expand_path(train_root) ? "train" : "main"
        end
      end
    end
  end
end
