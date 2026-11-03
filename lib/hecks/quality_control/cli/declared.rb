# frozen_string_literal: true

require_relative "../../../hecks"

module Hecks
  module QualityControlCli
    # Reads what the QualityControl bluebook declares as data, so a rule lives once, in the bluebook, and
    # the command that applies it asks the declaration instead of keeping a list of its own. A booted
    # ledger answers for itself; a caller with none (a spec, a bare adapter) reads the declarations of
    # this checkout's bluebook, loaded without binding any adapter.
    module Declared
      DIRECTORY = File.expand_path("..", __dir__)

      module_function

      # @param source [#bluebook, nil] a booted dispatcher or described domain, or nil
      # @return [Bluebook::Declaration] the QualityControl bluebook
      def bluebook(source = nil)
        source&.bluebook("QualityControl") || described.bluebook("QualityControl")
      end

      # @param source [#bluebook, nil] see `bluebook`
      # @param aggregate [String] the aggregate that owns the value object
      # @param object [String] the value object's name
      # @return [Array<Hash{Symbol => Object}>] its `member` rows
      def rows(source, aggregate, object)
        found = aggregate_of(source, aggregate).value_objects.find { |candidate| candidate.hecks_name == object }
        raise KeyError, "#{aggregate} declares no value object #{object}" unless found

        found.members
      end

      # @param source [#bluebook, nil] see `bluebook`
      # @param aggregate [String] the aggregate whose lifecycle declares the mark
      # @param name [String, Symbol] the mark
      # @return [Array<String>] the states it marks
      def marked(source, aggregate, name)
        aggregate_of(source, aggregate).lifecycle.marked(name) || raise(KeyError, "#{aggregate} marks no state #{name}")
      end

      def aggregate_of(source, name)
        bluebook(source).aggregates.find { |candidate| candidate.hecks_name == name } ||
          raise(KeyError, "QualityControl declares no aggregate #{name}")
      end

      def described = (@described ||= Hecks.describe(DIRECTORY))
      private_class_method :aggregate_of, :described
    end
  end
end
