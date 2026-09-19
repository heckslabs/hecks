require_relative "state_codec"
require_relative "../../runtime/errors"

module Hecks
  module Ports
    module Persistence
      # No adapter can build an `Instance` from undecoded state (Phase 2,
      # Track A, PR A3). Routing every adapter through `StateCodec` is a
      # convention until something refuses the bypass; this is that
      # something, and it is installed by `RepositoryFactory.build` — the
      # one place every runtime repository is made — so no adapter can opt
      # out of it.
      #
      # ## The mechanism, two halves
      #
      # 1. `guard!(adapter)` extends the adapter object (not its class,
      #    not a proxy — `is_a?`, `class`, and `===` stay the adapter's
      #    own) with a module that wraps every public method the adapter's
      #    class defines. Each call runs inside the boundary: a
      #    thread-local flag, re-entrant, restored on the way out. A block
      #    the caller passes (`transaction`, `with_write_lock`,
      #    `each_saga`) runs outside it — that block is the dispatch
      #    itself (hydrate, entity views, mutation), not adapter code.
      #    Reaching the adapter through `repository.adapter` (the query
      #    port, saga persistence, `bin/heki_compact`) is guarded all the
      #    same: the wrapper is on the object.
      #
      # 2. `Runtime::Instance#initialize` asks `check_state!` whenever it
      #    is handed `state:`. Outside the boundary that is a no-op; inside
      #    it, state `StateCodec.decoded?` rejects refuses by name. An
      #    `entries` answer is checked the same way on its way out, since a
      #    journal `Entry` is not an `Instance`.
      #
      # ## Checked, not silently decoded
      #
      # An adapter that forgets the codec is a bug in that adapter, and
      # decoding for it here would hide the forgetting. Hydration does not
      # respell keys either (A4) — `Value.hydrate` refuses a non-Symbol
      # top-level key everywhere — so this boundary's deep check and
      # hydration's shallow one agree.
      module CodecBoundary
        KEY = :hecks_persistence_codec_boundary

        module_function

        # Extends an adapter object so every public method its class defines runs inside the
        # boundary; guarding an adapter twice wraps it once.
        #
        # @param adapter [Object] a driven persistence adapter instance
        # @return [Object] the same adapter object, now including `Guarded`
        def guard!(adapter)
          adapter.extend(wrapper_for(adapter.class)) unless adapter.singleton_class.include?(Guarded)
          adapter
        end

        # Reports whether the current thread is executing inside a guarded adapter call.
        #
        # @return [Boolean] true between entering a guarded adapter method and yielding to the
        #   caller's block or returning
        def active? = Thread.current[KEY] == true

        # Runs the block with the boundary switched on for this thread, restoring the earlier
        # setting afterwards.
        #
        # @yield adapter code whose `Instance` construction is to be checked
        # @return [Object] the block's value
        def within(&) = with_flag(true, &)

        # Runs the block with the boundary switched off for this thread, restoring the earlier
        # setting afterwards.
        #
        # @yield caller code, such as a dispatch running inside the adapter's transaction
        # @return [Object] the block's value
        def outside(&) = with_flag(false, &)

        # Refuses state an adapter is about to build an `Instance` from unless it is decoded;
        # outside the boundary it checks nothing.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct the state
        #   belongs to
        # @param state [Hash, Runtime::Value] the state handed to `Runtime::Instance.new`
        # @return [nil] when the boundary is inactive or the state is decoded
        # @raise [Runtime::WiringError] if the boundary is active and
        #   `StateCodec.decoded?` rejects the state
        def check_state!(aggregate, state)
          return unless active?
          return if StateCodec.decoded?(aggregate, state)

          raise Runtime::WiringError,
                "a persistence adapter built a #{aggregate.name} record from undecoded state " \
                "(#{state.keys.inspect}) — decode stored state through " \
                "Hecks::Ports::Persistence::StateCodec.decode before handing it to Runtime::Instance"
        end

        # Refuses a guarded adapter's `entries` answer if any entry's state is undecoded.
        #
        # @param adapter [Object] the guarded adapter, asked for its `aggregate` and class name
        # @param entries [Array<Persistence::Entry>, Object] what the adapter's `entries`
        #   returned; anything that is not an Array passes through unchecked
        # @return [Array<Persistence::Entry>, Object] `entries` itself
        # @raise [Runtime::WiringError] if an `Entry` in the Array carries state
        #   `StateCodec.decoded?` rejects
        def check_entries!(adapter, entries)
          return entries unless entries.is_a?(Array)

          entries.each do |entry|
            next unless entry.is_a?(Entry) && !StateCodec.decoded?(adapter.aggregate, entry.state)

            raise Runtime::WiringError,
                  "#{adapter.class} answered a #{adapter.aggregate.name} journal entry #{entry.id.inspect} with " \
                  "undecoded state — decode it through Hecks::Ports::Persistence::StateCodec.decode"
          end
          entries
        end

        # Sets the thread-local boundary flag for the length of the block, which is what makes
        # the boundary re-entrant.
        #
        # @param value [Boolean] true to switch the boundary on, false to switch it off
        # @yield the code to run under that setting
        # @return [Object] the block's value; the earlier flag is restored even when the
        #   block raises
        def with_flag(value)
          previous = Thread.current[KEY]
          Thread.current[KEY] = value
          yield
        ensure
          Thread.current[KEY] = previous
        end

        # Marks a guarded adapter so a second `guard!` (a projection and an
        # authoritative repository built over one object) never wraps twice.
        module Guarded; end

        # Filled lazily under `WRAPPERS_LOCK`, one entry per adapter class —
        # a cache, deliberately mutable.
        WRAPPERS = {} # rubocop:disable Style/MutableConstant
        WRAPPERS_LOCK = Mutex.new

        # Builds, or fetches from the cache, the module that guards one adapter class.
        #
        # One wrapper module per adapter class, built once: every public
        # instance method the class (and its ancestors below Object)
        # defines, each forwarding to `super` inside the boundary.
        #
        # @param klass [Class] the adapter's class
        # @return [Module] an anonymous module including `Guarded`, meant to be `extend`ed onto
        #   instances of `klass`
        def wrapper_for(klass)
          WRAPPERS_LOCK.synchronize do
            WRAPPERS[klass] ||= Module.new do
              include Guarded

              (klass.public_instance_methods - Object.public_instance_methods).each do |name|
                define_method(name) do |*args, **kwargs, &block|
                  result = CodecBoundary.within { super(*args, **kwargs, &CodecBoundary.outside_block(block)) }
                  name == :entries ? CodecBoundary.check_entries!(self, result) : result
                end
              end
            end
          end
        end

        # Wraps the caller's own block so it runs outside the boundary
        # whenever the adapter yields to it.
        #
        # @param block [Proc, nil] the block the caller passed to the adapter method
        # @return [Proc, nil] a proc forwarding its arguments to `block` under `outside`; nil
        #   when no block was given
        def outside_block(block)
          return nil unless block

          proc { |*yielded, **yielded_kwargs, &inner| outside { block.call(*yielded, **yielded_kwargs, &inner) } }
        end
      end
    end
  end
end
