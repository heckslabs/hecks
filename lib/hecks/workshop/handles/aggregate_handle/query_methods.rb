# Hecks::Workshop::AggregateHandle::QueryMethods
#
# Query and scope handle methods with REPL feedback.
#
module Hecks
  class Workshop
    class AggregateHandle
      module QueryMethods
        def query(name, &block)
          @builder.query(name, &block)
          puts "#{name} query added to #{@name}"
          self
        end

        def scope(name, conditions = nil, &block)
          @builder.scope(name, conditions, &block)
          puts "#{name} scope added to #{@name}"
          self
        end

        def computed(name, &block)
          @builder.computed(name, &block)
          puts "#{name} computed attribute added to #{@name}"
          self
        end
      end
    end
  end
end
