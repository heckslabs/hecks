module RuboCop
  module Cop
    module Hecks
      # FLAGS PLAIN `@ivar` MUTATION inside a class this codebase already
      # knows is a thread-shared singleton — one `Dispatcher`/`Registry`
      # instance lives for the life of a boot and is dispatched through
      # from every thread of a Puma worker pool (or any other multi-
      # threaded host), so a plain instance variable on either class is
      # shared, mutable state with no per-thread or mutex-guarded
      # isolation at all.
      #
      # THIS IS THE MECHANICAL FOLLOW-UP to a real bug already fixed here
      # (see `dispatcher.rb`'s own `#reenter` comment, and
      # `spec/runtime/dispatcher_spec.rb`): `@reaction_depth` used to be a
      # plain ivar on `Dispatcher`, so two threads' concurrent top-level
      # dispatches corrupted each other's view of "how deep into a
      # reaction cascade am I". The fix moved that one ivar to
      # `Thread.current[:hecks_reaction_depth]`. This cop exists so the
      # NEXT plain ivar someone adds to either class gets flagged before
      # it becomes the next instance of the same bug, rather than after.
      #
      # SCOPED NARROWLY ON PURPOSE — by class name
      # (`Hecks::Runtime::Dispatcher`/`Hecks::Runtime::Registry`), not by
      # blanket-flagging every ivar mutation in the codebase. Most classes
      # in this codebase are NOT shared across threads (a fresh value
      # object per call, a builder used once at boot) and ivar mutation
      # there is completely ordinary Ruby with no hazard behind it at
      # all — flagging it everywhere would be noise nobody trusts, the
      # same reasoning `.rubocop.yml`'s own header gives for every other
      # cop in this repo.
      #
      # WHAT COUNTS AS "PLAIN": `@ivar = ...`, `@ivar ||= ...`, `@ivar +=
      # ...`, `@ivar << ...`, `@ivar[k] = v`. `initialize` is exempt — an
      # ivar being SET UP for the first time, before any other thread can
      # possibly hold a reference to this object, is not the hazard (see
      # `Registry#initialize`'s own `@saga_mutex = Mutex.new`, which this
      # cop must not flag). `Thread.current[...]`-backed state and a
      # `Mutex`-guarded critical section are exactly the two idioms this
      # codebase has already established for this — see `Dispatcher
      # #reenter` and `Registry#saga_mutex` respectively — so the message
      # points at both rather than inventing a third.
      #
      # @example
      #   # bad
      #   class Dispatcher
      #     def reenter(verb)
      #       @reaction_depth = @reaction_depth.to_i + 1
      #     end
      #   end
      #
      #   # good
      #   class Dispatcher
      #     def reenter(verb)
      #       Thread.current[:hecks_reaction_depth] = Thread.current[:hecks_reaction_depth].to_i + 1
      #     end
      #   end
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
          # A PLAIN `@x = 1` parses as `(ivasgn :@x (int 1))` — two
          # children. The commissioner also visits the BARE `(ivasgn :@x)`
          # node nested one level inside an `op_asgn`/`or_asgn` (`@x += 1`,
          # `@x ||= 1`) as its own `ivasgn` node with only one child — that
          # one is handled by `on_op_asgn`/`on_or_asgn` below instead, so
          # it's skipped here to avoid double-reporting the same mutation.
          return unless node.children.size == 2

          check(node, node.children.first)
        end

        def on_op_asgn(node)
          # `@x += 1` parses as `(op_asgn (ivasgn :@x) :+ (int 1))` — the
          # target is an `ivasgn` node carrying JUST the name (no value
          # child, unlike a plain `@x = 1`), not an `ivar` node.
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

          # `@ivar << x` — the receiver IS the ivar.
          # `@ivar[k] = v` — the receiver is a `send(@ivar, :[], k)`, whose
          # own receiver is the ivar (`node.receiver.receiver`).
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

        # Walks outward to the nearest enclosing `class` node and returns
        # its own short name (`Dispatcher`, not the fully-qualified
        # `Hecks::Runtime::Dispatcher`) — good enough to match this repo's
        # own one-class-per-file layout without needing full namespace
        # resolution, and avoids a false negative on `class Dispatcher`
        # bodies that reopen the class from inside the `Hecks::Runtime`
        # module (this repo's actual style) as much as one written as
        # `class Hecks::Runtime::Dispatcher`.
        def enclosing_class_name(node)
          klass = node.each_ancestor(:class).first
          return nil unless klass

          const_node = klass.identifier
          const_node.const_name.to_s.split("::").last
        end

        # `initialize` is where an ivar is set up for the first time —
        # before this object has been handed to a caller at all, so no
        # other thread can hold a reference to mutate concurrently with
        # it. Also exempts `initialize` methods defined on an object
        # reopened via `class << self` or nested module — `each_ancestor`
        # naturally stops at the nearest enclosing `def`, matching Ruby's
        # own method-scoping.
        def inside_initialize?(node)
          def_node = node.each_ancestor(:def, :defs).first
          return false unless def_node

          def_node.method?(:initialize)
        end
      end
    end
  end
end
