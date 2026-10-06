# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module Payload
        # What the generators read from a domain chapter about one aggregate the content system
        # drives:
        # its attributes with the shape each takes over the wire, the command that creates it, the
        # lifecycle edges, and the role its commands declare.
        #
        # The model is pure data. It refuses an aggregate it cannot drive, naming why, so a project
        # learns at generation time rather than from a runtime refusal.
        class Model
          # One attribute: `name` is the domain's (snake case), `ts` the camel case the content
          # system
          # uses, `shape` one of :value, :url, :address, :integer or :composite, and `parts` the
          # attributes of a composite value object.
          Attr = Struct.new(:name, :ts, :shape, :wire_key, :optional, :list, :type, :parts, keyword_init: true)

          # One aggregate: `noun` ("Event"), `fqn` ("Club::Event"), `create` ({verb:, status:}),
          # `edges` (status => { verb => status }) and `attrs` (the identity first).
          Aggregate = Struct.new(:noun, :fqn, :create, :edges, :attrs, :identity, :role, keyword_init: true)

          # The single attribute names a one-attribute value object may carry, with the shape each
          # is.
          SINGLE = { "value" => :value, "url" => :url, "address" => :address }.freeze

          # @param chapter [Bluebook::Chapter] the domain chapter
          # @param skip [Array<String>] aggregates to leave out
          # @return [Array<Aggregate>] each aggregate with a lifecycle and a creating command
          # @raise [ArgumentError] when such an aggregate cannot be driven
          def self.read(chapter, skip: [])
            chapter.aggregates.select { |agg| agg.lifecycle && !skip.include?(agg.hecks_name) }
                   .map { |agg| new(chapter, agg).aggregate }
          end

          # @return [Aggregate] the aggregate's model
          attr_reader :aggregate

          def initialize(chapter, agg)
            @chapter = chapter
            @agg = agg
            @aggregate = Aggregate.new(noun: agg.hecks_name, fqn: "#{chapter.name}::#{agg.hecks_name}", create: create,
                                       edges: edges, attrs: attrs, identity: agg.identified_by.to_s, role: role)
          end

          private

          def create
            command = @agg.commands.find(&:creates?)
            raise ArgumentError, "#{@agg.hecks_name} has no command that creates it" unless command
            raise ArgumentError, "#{@agg.hecks_name}'s lifecycle has no default status" unless @agg.lifecycle.default

            { verb: command.hecks_name, status: @agg.lifecycle.default }
          end

          def edges
            creating = @agg.commands.select(&:creates?).map(&:hecks_name)
            map = Hash.new { |hash, key| hash[key] = {} }
            @agg.lifecycle.transitions.each do |verb, move|
              next if creating.include?(verb)

              Array(move.from).each { |from| map[from][verb] = move.target }
              map[move.target]
            end
            map.transform_values(&:dup)
          end

          def role
            roles = @agg.commands.filter_map { |command| command.role if command.respond_to?(:role) }.uniq
            if roles.size > 1
              raise ArgumentError,
                    "#{@agg.hecks_name}'s commands declare #{roles.size} roles; the driver acts as one"
            end

            roles.first
          end

          def attrs
            @agg.attributes.reject { |attribute| attribute.name == @agg.lifecycle.field }.map { |attribute| attr(attribute) }
          end

          def attr(attribute)
            object = value_object(attribute.type)
            unless object
              raise ArgumentError,
                    "#{@agg.hecks_name}.#{attribute.name} is a #{attribute.type}; the driver needs a value object"
            end

            members = object.attributes
            shape, key, parts = shape_of(attribute, members)
            Attr.new(name: attribute.name.to_s, ts: camel(attribute.name), shape: shape, wire_key: key,
                     optional: attribute.optional?, list: attribute.list?, type: attribute.type, parts: parts)
          end

          def shape_of(attribute, members)
            if members.size == 1 && SINGLE.key?(members.first.name.to_s)
              key = members.first.name.to_s
              [members.first.type.to_s == "Integer" ? :integer : SINGLE.fetch(key), key, nil]
            elsif attribute.list? && members.size > 1
              [:composite, nil, members.map { |member| part(member) }]
            else
              raise ArgumentError, "#{@agg.hecks_name}.#{attribute.name} is #{attribute.type}, which the driver cannot carry"
            end
          end

          def part(member)
            unless member.type.to_s == "String"
              raise ArgumentError, "#{@agg.hecks_name}'s #{member.name} is a #{member.type}; a composite carries text only"
            end

            Attr.new(name: member.name.to_s, ts: camel(member.name), shape: :value, type: member.type.to_s, optional: false)
          end

          def value_object(type)
            @agg.value_objects.find { |object| object.hecks_name == type.to_s }
          end

          def camel(name)
            first, *rest = name.to_s.split("_")
            first + rest.map(&:capitalize).join
          end
        end
      end
    end
  end
end
