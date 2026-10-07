# frozen_string_literal: true

require_relative "attributes"
require_relative "media"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What the editor reads of a domain chapter, as plain data: each aggregate with its
        # identity, attributes, value objects, lifecycle, commands and queries. The editor's
        # `schema.ts` is this hash as a typed constant, and nothing else about the domain reaches
        # the generated files, so the output is a pure function of the chapter.
        #
        # An aggregate that registers pictures (see `Media`) is also named under `media`, so the
        # editor can offer an upload; a chapter with none has no such key.
        #
        # A query that `returns` a value object is answered outside the domain and is left out: the
        # host refuses it, so a list cannot be built from it.
        class Schema
          # @param chapter [Bluebook::Chapter] the domain's chapter
          # @param skip [Array<String>] aggregates to leave out
          # @return [Hash{String => Object}] the domain's name and its aggregates
          # @raise [ArgumentError] when no aggregate is left
          def self.read(chapter, skip: [])
            aggregates = chapter.aggregates.reject { |agg| skip.include?(agg.hecks_name) }
            raise ArgumentError, "the #{chapter.name} chapter has no aggregate to edit" if aggregates.empty?

            shaped = aggregates.map { |agg| new(agg).to_h }
            media = Media.read(shaped)
            { "domain" => chapter.name, "aggregates" => shaped, **(media ? { "media" => media } : {}) }
          end

          # @param aggregate [Bluebook::Aggregate] one aggregate of the chapter
          def initialize(aggregate)
            @agg = aggregate
            @attributes = Attributes.new(aggregate.value_objects)
          end

          # @return [Hash{String => Object}] the aggregate as the editor reads it
          def to_h
            { "name" => @agg.hecks_name, "description" => @agg.description, "identity" => @agg.identified_by.to_s,
              "lifecycle" => lifecycle, "attributes" => attributes(@agg.attributes.reject { |a| a.name == lifecycle_field }),
              "valueObjects" => value_objects, "commands" => @agg.commands.map { |command| command(command) },
              "queries" => queries }
          end

          private

          def lifecycle_field = @agg.lifecycle&.field

          def attributes(list) = list.map { |attribute| @attributes.of(attribute) }

          def value_objects
            @agg.value_objects.to_h { |object| [object.hecks_name, attributes(object.attributes)] }
          end

          def lifecycle
            lifecycle = @agg.lifecycle
            return nil unless lifecycle

            { "field" => lifecycle.field.to_s, "default" => lifecycle.default,
              "transitions" => lifecycle.transitions.map { |verb, move| transition(verb, move) } }
          end

          def transition(verb, move)
            { "verb" => verb, "from" => Array(move.from), "to" => move.target }
          end

          def command(command)
            { "name" => command.hecks_name, "goal" => command.goal, "role" => command.role, "creates" => command.creates?,
              "on" => command.creates? ? nil : command.references.to_s, "attributes" => attributes(command.attributes) }
          end

          def queries
            @agg.queries.reject(&:returns).map do |query|
              { "name" => query.name, "description" => query.description, "attributes" => attributes(query.attributes) }
            end
          end
        end
      end
    end
  end
end
