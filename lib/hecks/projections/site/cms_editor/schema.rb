# frozen_string_literal: true

require_relative "attributes"
require_relative "clearing"
require_relative "composition"
require_relative "destructive"
require_relative "media"
require_relative "pickers"

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
          # @param chapters [Bluebook::Chapter, Array<Bluebook::Chapter>] the chapter, or the
          #   chapters in the order the row names them; the first names the domain addressed
          # @param skip [Array<String>] aggregates to leave out: `Name`, or `Chapter::Name`
          # @param pictures [Bluebook::Chapter, nil] another chapter whose picture aggregate the
          #   editor's pictures use, in place of any in `chapters`
          # @param roles [Hash{String => Array<String>}] the roles each chapter is limited to
          # @return [Hash{String => Object}] the domain's name and its aggregates; `chapters` too
          #   when there are several
          # @raise [ArgumentError] when no aggregate is left, or `pictures` has no picture aggregate
          def self.read(chapters, skip: [], pictures: nil, roles: {})
            list = chapters.is_a?(Array) ? chapters : [chapters]
            shaped = Composition.aggregates(list, skip: skip, roles: roles) { |agg| new(agg).to_h }
            raise ArgumentError, "the #{list.map(&:name).join(", ")} chapter has no aggregate to edit" if shaped.empty?

            media = pictures ? elsewhere(pictures) : within(shaped, list.first.name)
            assemble(list, Pickers.apply(shaped, media), media)
          end

          # @return [Hash{String => Object}] the schema: the domain, the chapters when several, the
          #   aggregates, and the picture aggregate when there is one
          def self.assemble(list, aggregates, media)
            chapters = list.size > 1 ? { "chapters" => list.map(&:name) } : {}
            { "domain" => list.first.name, **chapters, "aggregates" => aggregates, **(media ? { "media" => media } : {}) }
          end

          # The picture aggregate among the editor's own, with the chapter that holds it when that
          # is not the first, since the host is addressed by chapter.
          #
          # @return [Hash{String => Object}, nil] the picture aggregate, as `Media` describes it
          def self.within(shaped, first)
            found = Media.read(shaped)
            chapter = found&.delete("chapter")
            chapter && chapter != first ? found.merge("domain" => chapter) : found
          end

          # The picture aggregate of another chapter: the same record as one in the editor's own
          # chapter, with the chapter's name and the aggregate itself, since the editor's own
          # aggregates do not hold it.
          #
          # @return [Hash{String => Object}] the picture aggregate, as `Media` describes it
          # @raise [ArgumentError] when the chapter has no aggregate that registers pictures
          def self.elsewhere(chapter)
            shaped = chapter.aggregates.map { |agg| new(agg).to_h }
            found = Media.read(shaped)
            raise ArgumentError, "the #{chapter.name} chapter has no aggregate that registers pictures" unless found

            found.merge("domain" => chapter.name, "definition" => shaped.find { |agg| agg["name"] == found["aggregate"] })
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
            @lifecycle ||= shaped_lifecycle
          end

          def shaped_lifecycle
            lifecycle = @agg.lifecycle
            return nil unless lifecycle

            shaped = { "field" => lifecycle.field.to_s, "default" => lifecycle.default,
                       "transitions" => lifecycle.transitions.map { |verb, move| transition(verb, move) } }
            shaped.merge("tones" => Destructive.tones(shaped))
          end

          def transition(verb, move)
            { "verb" => verb, "from" => Array(move.from), "to" => move.target }
          end

          def command(command)
            { "name" => command.hecks_name, "goal" => command.goal, "role" => command.role, "creates" => command.creates?,
              "on" => command.creates? ? nil : command.references.to_s,
              "destructive" => Destructive.command?(command.hecks_name, lifecycle),
              "attributes" => attributes(command.attributes) }
              .then { |shaped| clearing(shaped, command) }
          end

          # Leaves the arguments that only clear (see `Clearing`) out of the command's form, and
          # names those that are lists as `empty`, for the editor to send as empty lists.
          def clearing(shaped, command) = Clearing.apply(shaped, Clearing.of(command, @agg))

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
