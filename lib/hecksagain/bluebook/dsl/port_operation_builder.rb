module Hecksagain
  module Bluebook
    module DSL
      class PortOperationBuilder
        include AttributeCollector

        def initialize(name, owner: nil)
          @name  = name
          @owner = owner
          @emits = []
        end

        # ALWAYS an attribute, never the self-reference `CommandBuilder`
        # spells — a port operation has no `creates?`/`acts_on` distinction
        # to protect, so there is nothing for the self-reference branch to be
        # FOR here. `reference_to Payment, as: :payment_id` reads the same
        # even though the target happens to equal the owning aggregate.
        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          attribute(as || :"#{Naming.snake(target)}_id", Reference.new(target))
        end

        def emits(event_name) = @emits << event_name.to_s

        def build
          operation = PortOperation.new(name: @name, attributes: attributes, emits: @emits)

          raise Malformed,
                "#{@name} declares no emits — an operation with nothing to say " \
                "afterward is a call into nothing" if @emits.empty?

          # Only enforced when this operation belongs to ONE aggregate — a
          # port declared bare at a hecksagon's root has no single owner for
          # an emitted event to be ABOUT, so nothing here can require one.
          if @owner
            raise Malformed,
                  "#{@name} names no reference_to #{@owner} — an operation needs one to " \
                  "say which #{@owner} its emitted event belongs to" unless operation.identity_attribute(@owner)
          end

          operation
        end

        def self.build(name, owner: nil, &block)
          builder = new(name, owner: owner)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
