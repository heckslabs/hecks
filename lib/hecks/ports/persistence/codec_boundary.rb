require_relative "state_codec"
require_relative "../../runtime/errors"

module Hecks
  module Ports
    module Persistence
      # Refuses to let a guarded adapter build an `Instance` from undecoded state.
      # `RepositoryFactory.build` installs it, so no adapter can opt out.
      module CodecBoundary
        KEY = :hecks_persistence_codec_boundary

        module_function

        # Extends the adapter object so every public method its class defines runs inside the
        # boundary; guarding twice wraps once.
        #
        # @param adapter [Object] a driven persistence adapter instance
        # @return [Object] the same adapter object, now including `Guarded`
        def guard!(adapter)
          adapter.extend(wrapper_for(adapter.class)) unless adapter.singleton_class.include?(Guarded)
          adapter
        end

        # Whether this thread is currently inside a guarded adapter call.
        #
        # @return [Boolean]
        def active? = Thread.current[KEY] == true

        # Runs the block with the boundary on for this thread; re-entrant.
        def within(&) = with_flag(true, &)

        # Runs the block with the boundary off for this thread; re-entrant.
        def outside(&) = with_flag(false, &)

        # Refuses undecoded state headed for `Runtime::Instance.new`; a no-op outside the boundary.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct the state
        #   belongs to
        # @param state [Hash, Runtime::Value] the state handed to `Runtime::Instance.new`
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
        # A journal `Entry` is not an `Instance`, so `check_state!` never sees it.
        #
        # @param adapter [Object] the guarded adapter
        # @param entries [Array<Persistence::Entry>, Object] anything but an Array passes unchecked
        # @return [Array<Persistence::Entry>, Object] `entries` itself
        # @raise [Runtime::WiringError] if an `Entry` carries state `StateCodec.decoded?` rejects
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

        # Sets the thread-local flag for the block and restores it after, even on a raise.
        def with_flag(value)
          previous = Thread.current[KEY]
          Thread.current[KEY] = value
          yield
        ensure
          Thread.current[KEY] = previous
        end

        # Marks a guarded adapter so a second `guard!` never wraps it twice.
        module Guarded; end

        # A per-adapter-class cache, filled lazily under `WRAPPERS_LOCK`; deliberately mutable.
        WRAPPERS = {} # rubocop:disable Style/MutableConstant
        WRAPPERS_LOCK = Mutex.new

        # Builds, or fetches from the cache, the module that guards one adapter class.
        # Each public method forwards to `super` inside the boundary.
        #
        # @param klass [Class] the adapter's class
        # @return [Module] an anonymous module including `Guarded`, to `extend` onto instances
        def wrapper_for(klass)
          WRAPPERS_LOCK.synchronize { WRAPPERS[klass] ||= build_wrapper(klass) }
        end

        # Builds the module whose methods forward to the adapter class's own, inside the boundary.
        #
        # @param klass [Class] the adapter's class
        # @return [Module] an anonymous module including `Guarded`
        def build_wrapper(klass)
          wrapper = Module.new { include Guarded }
          (klass.public_instance_methods - Object.public_instance_methods).each { |name| guard_method(wrapper, name) }
          wrapper
        end

        # Defines one guarded method on `wrapper`; `entries` answers are also checked for decoding.
        #
        # @param wrapper [Module] the module under construction
        # @param name [Symbol] the adapter method to guard
        # @return [Symbol] the defined method name
        def guard_method(wrapper, name)
          wrapper.define_method(name) do |*args, **kwargs, &block|
            result = CodecBoundary.within { super(*args, **kwargs, &CodecBoundary.outside_block(block)) }
            name == :entries ? CodecBoundary.check_entries!(self, result) : result
          end
        end

        # Wraps the caller's block so it runs outside the boundary when the adapter yields to it;
        # that block is the dispatch itself, not adapter code.
        def outside_block(block)
          return nil unless block

          proc { |*yielded, **yielded_kwargs, &inner| outside { block.call(*yielded, **yielded_kwargs, &inner) } }
        end
      end
    end
  end
end
