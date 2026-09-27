module RuboCop
  module Cop
    module Hecks
      # Flags plain `@ivar` mutation inside the thread-shared `Dispatcher` and `Registry` classes.
      # `initialize` is exempt; use `Thread.current[...]` or a `Mutex` elsewhere.
      #
      # @example
      #   # bad
      #   @reaction_depth = @reaction_depth.to_i + 1
      #
      #   # good
      #   Thread.current[:hecks_reaction_depth] = Thread.current[:hecks_reaction_depth].to_i + 1
      class ThreadSharedIvarMutation < Base
        MSG = "`%<ivar>s` is a plain instance variable mutated outside `initialize` on " \
              "%<klass>s, which is shared across every thread dispatching through it " \
              "(a Puma worker pool, say) — two concurrent threads would corrupt each " \
              "other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` " \
              "(see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread " \
              "state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the " \
              "state genuinely must be shared.".freeze

        THREAD_SHARED_CLASSES = ["Dispatcher", "Registry"].freeze

        RESTRICT_ON_SEND = [:<<, :[]=].freeze

        def on_ivasgn(node)
          # Skips the bare one-child `ivasgn` nested in `op_asgn`/`or_asgn`; those handlers
          # report it, so this avoids a double offense.
          return unless node.children.size == 2

          check(node, node.children.first)
        end

        def on_op_asgn(node)
          # The target of `@x += 1` is a value-less `ivasgn` node, not an `ivar`.
          ivar_node = node.children.first
          return unless ivar_node.is_a?(RuboCop::AST::Node) && ivar_node.ivasgn_type?

          check(node, ivar_node.children.first)
        end

        def on_or_asgn(node)
          on_op_asgn(node)
        end

        def on_send(node)
          return unless RESTRICT_ON_SEND.include?(node.method_name)

          receiver = node.receiver
          return unless receiver

          # `@ivar << x` has the ivar as receiver; `@ivar[k] = v` has it one `send` deeper.
          ivar_node = if receiver.ivar_type?
                        receiver
                      elsif receiver.send_type? && receiver.receiver&.ivar_type?
                        receiver.receiver
                      end
          return unless ivar_node

          check(node, ivar_node.children.first)
        end

        private

        def check(node, ivar_name)
          return unless inside_thread_shared_class?(node)
          return if inside_initialize?(node)

          add_offense(node, message: format(MSG, ivar: ivar_name, klass: enclosing_class_name(node)))
        end

        def inside_thread_shared_class?(node)
          !!enclosing_class_name(node)&.then { |name| THREAD_SHARED_CLASSES.include?(name) }
        end

        # Uses the short class name so both nested and `Hecks::Runtime::Dispatcher` styles match.
        def enclosing_class_name(node)
          klass = node.each_ancestor(:class).first
          return nil unless klass

          const_node = klass.identifier
          const_node.const_name.to_s.split("::").last
        end

        # An ivar set in `initialize` cannot yet be shared with another thread.
        def inside_initialize?(node)
          def_node = node.each_ancestor(:def, :defs).first
          return false unless def_node

          def_node.method?(:initialize)
        end
      end
    end
  end
end
