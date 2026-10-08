# frozen_string_literal: true

require_relative "clearing"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # An aggregate that keeps a draft of a document body beside the live one: the editor
        # writes the draft as the person types and publishes it only when asked.
        #
        # A command on the aggregate whose every argument is `draft_<x>` (the aggregate holds
        # both `draft_<x>` and `<x>`, of one type, and some `<x>` is a rich-text body) saves the
        # draft. A command with a `sets <x>, to: state(:draft_<x>)` mutation publishes it; one
        # that only empties `draft_<x>` (see `Clearing`) discards it. A missing publishing or
        # discarding command is left out.
        module Drafts
          # What a draft attribute's name starts with.
          PREFIX = "draft_"

          module_function

          # @param agg [Bluebook::Aggregate] the aggregate
          # @param attributes [Array<Hash{String => Object}>] its attributes as `Schema` shapes
          #   them
          # @return [Hash{String => String}, nil] `attribute` (the draft), `live`, `save`, and
          #   `publish` and `discard` when the aggregate has them; nil when it keeps no drafts
          def of(agg, attributes)
            found = agg.commands.lazy.filter_map { |command| saving(command, agg, attributes) }.first
            return nil unless found

            found.merge("publish" => publishing(agg, found), "discard" => discarding(agg, found)).compact
          end

          # @return [Hash{String => String}, nil] the draft and live attributes `command` saves
          def saving(command, agg, attributes)
            return nil unless acts_on?(command, agg) && !command.attributes.empty?

            lives = command.attributes.map { |argument| live_of(argument, agg) }
            live = lives.all? ? lives.find { |name| body?(name, attributes) } : nil
            live && { "attribute" => "#{PREFIX}#{live}", "live" => live, "save" => command.hecks_name }
          end

          # @return [Boolean] whether the command acts on an existing instance of the aggregate
          def acts_on?(command, agg) = !command.creates? && command.references.to_s == agg.hecks_name

          # @return [String, nil] the live attribute `argument` is the draft of, when it is one
          def live_of(argument, agg)
            name = argument.name.to_s
            live = name.delete_prefix(PREFIX)
            return nil unless name.start_with?(PREFIX) && same_type?(agg, name, live) && agg.attributes.any? do |held|
              held.name.to_s == name
            end

            live
          end

          # @return [Boolean] whether the aggregate holds both attributes, of one type
          def same_type?(agg, draft, live)
            types = [draft, live].map { |name| agg.attributes.find { |held| held.name.to_s == name }&.type.to_s }
            types.none?(&:empty?) && types.uniq.size == 1
          end

          # @return [Boolean] whether the named attribute is a rich-text body
          def body?(name, attributes) = attributes.any? { |attr| attr["name"] == name && attr["widget"] == "body" }

          # @return [String, nil] the command that moves the draft into the live attribute
          def publishing(agg, found)
            agg.commands.find { |command| acts_on?(command, agg) && promotes?(command, found) }&.hecks_name
          end

          # @return [String, nil] the command that empties the draft and changes nothing live
          def discarding(agg, found)
            agg.commands.find { |command| acts_on?(command, agg) && empties?(command, agg, found) }&.hecks_name
          end

          def promotes?(command, found)
            command.mutations.any? do |mutation|
              mutation.target.to_s == found["live"] && mutation.source.is_a?(Hecks::StateRef) &&
                mutation.source.name.to_s == found["attribute"]
            end
          end

          def empties?(command, agg, found)
            return false if command.hecks_name == found["save"] || targets_of(command) != [found["attribute"]]

            clears = Clearing.of(command, agg).map { |argument| argument.name.to_s }
            command.mutations.all? { |mutation| clears.include?(mutation.source.to_s) }
          end

          def targets_of(command) = command.mutations.map { |mutation| mutation.target.to_s }
        end
      end
    end
  end
end
