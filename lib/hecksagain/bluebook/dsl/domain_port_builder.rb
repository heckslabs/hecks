module Hecksagain
  module Bluebook
    module DSL
      class DomainPortBuilder
        def initialize(name, owner: nil)
          @name       = name
          @owner      = owner
          @operations = []
        end

        def operation(name, &block)
          @operations << PortOperationBuilder.build(name, owner: @owner, &block)
        end

        # THE DRIVEN HALF OF THE SAME WORD. `operation`/`emits` translates an
        # inbound fact into this domain's own event vocabulary — there is no
        # channel back to a caller beyond the events it emits. `verb` is the
        # opposite direction: the domain calling OUT to a swappable adapter
        # and getting a real value back (a checkout URL, a fetched document),
        # exactly what `Hecks.port "name" do verb "x" end` already builds —
        # this is that same `IR::Port`, reached from the same `port` call
        # `operation` already lives under, so a project's own resource ports
        # read next to their binding instead of in a separate file. One port,
        # one shape or the other — never both.
        def verb(value) = @verb = value.to_s

        def build
          if @verb && !@operations.empty?
            raise Malformed, "#{@name} declares both a verb and operations — a port is one or the other, not both"
          end

          return IR::Port.new(name: @name, verb: @verb, signal: :reply) if @verb

          raise Malformed, "#{@name} declares no verb and no operations" if @operations.empty?

          IR::DomainPort.new(name: @name, operations: @operations)
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
