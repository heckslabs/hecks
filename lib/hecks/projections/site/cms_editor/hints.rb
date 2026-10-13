# frozen_string_literal: true

require_relative "key_kinds"
require_relative "moment"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What one attribute's names, pattern and closed set say about how a value of it is
        # entered: a moment (see `Moment`), a `<kind>:<slug>` key (see `KeyKinds`) or one of a
        # closed set's members (a `one_of`, or one invariant that lists the literals). A value
        # object with a single plain part is entered as that part, so the part's pattern and the
        # value object's names count; a value object of several parts has parts of its own, each
        # read the same way.
        class Hints
          # @param objects [Hash{String => Bluebook::ValueObject}] the value objects by name
          def initialize(objects)
            @objects = objects
          end

          # @param attribute [Bluebook::Attribute] a declared attribute
          # @return [Hash{String => Object}] `widget`, `keys` and `options` when the attribute has
          #   them
          def of(attribute)
            leaf, names = leaf(attribute)
            return {} unless leaf

            { **moment(leaf, names), **keys(leaf), **options(attribute, leaf) }
          end

          private

          # @return [Array(Bluebook::Attribute, Array<String>), nil] the attribute that holds the
          #   value and the names it goes by, or nil for a reference or a value object of parts
          def leaf(attribute)
            return nil if attribute.type.is_a?(Bluebook::Reference)

            object = @objects[attribute.type.to_s]
            return [attribute, [attribute.name.to_s]] unless object

            part = plain_part(object)
            part && [part, [attribute.name.to_s, attribute.type.to_s, part.name.to_s]]
          end

          # @return [Bluebook::Attribute, nil] the one part of a value object that is a plain value
          def plain_part(object)
            part = object.attributes.first
            part if object.attributes.size == 1 && !part.list? && !@objects.key?(part.type.to_s)
          end

          def moment(leaf, names)
            widget = Moment.widget(names) if leaf.type.to_s == "Integer"
            widget ? { "widget" => widget } : {}
          end

          # A value object declared a closed set (`one_of`) is entered by choosing one of its
          # members.
          def options(attribute, leaf)
            object = @objects[attribute.type.to_s]
            return {} unless object

            members = object.closed_set? ? object.members.filter_map { |member| member[leaf.name] }.uniq : spelled(object, leaf)
            members.empty? ? {} : { "options" => members.map(&:to_s) }
          end

          # A closed set a value object spells as one invariant, `value == "a" || value == "b"`:
          # the part is one of those literals, which is what a `one_of` would have said.
          #
          # @return [Array<String>] the literals, or none when no invariant is exactly that
          def spelled(object, leaf)
            name = Regexp.escape(leaf.name.to_s)
            same = /\A#{name} == "[^"]*"(?: \|\| #{name} == "[^"]*")*\z/
            rule = object.invariants.map { |candidate| candidate.canonical.to_s }.find { |text| same.match?(text) }
            rule ? rule.scan(/"([^"]*)"/).flatten : []
          end

          def keys(leaf)
            kinds = KeyKinds.of(leaf.pattern)
            kinds.empty? ? {} : { "keys" => kinds }
          end
        end
      end
    end
  end
end
