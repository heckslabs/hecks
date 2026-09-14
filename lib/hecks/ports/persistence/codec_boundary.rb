require_relative "state_codec"
require_relative "../../runtime/errors"

module Hecks
  module Ports
    module Persistence
      # NO ADAPTER CAN BUILD AN `Instance` FROM UNDECODED STATE (Phase 2,
      # Track A, PR A3). Routing every adapter through `StateCodec` is a
      # convention until something refuses the bypass; this is that
      # something, and it is installed by `RepositoryFactory.build` — the
      # one place every runtime repository is made — so no adapter can opt
      # out of it.
      #
      # THE MECHANISM, two halves:
      #
      # 1. `guard!(adapter)` extends the adapter OBJECT (not its class,
      #    not a proxy — `is_a?`, `class`, and `===` stay the adapter's
      #    own) with a module that wraps every public method the adapter's
      #    class defines. Each call runs inside the boundary: a
      #    thread-local flag, re-entrant, restored on the way out. A block
      #    the CALLER passes (`transaction`, `with_write_lock`,
      #    `each_saga`) runs OUTSIDE it — that block is the dispatch
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
      # Checked, not silently decoded: an adapter that forgets the codec is
      # a bug in that adapter, and `Instance`'s own hydration reads either
      # key spelling — decoding for it here would hide the forgetting
      # until A4 removes that dual-spelling read and data goes missing.
      module CodecBoundary
        KEY = :hecks_persistence_codec_boundary

        module_function

        def guard!(adapter)
          adapter.extend(wrapper_for(adapter.class)) unless adapter.singleton_class.include?(Guarded)
          adapter
        end

        def active? = Thread.current[KEY] == true

        def within(&) = with_flag(true, &)
        def outside(&) = with_flag(false, &)

        def check_state!(aggregate, state)
          return unless active?
          return if StateCodec.decoded?(aggregate, state)

          raise Runtime::WiringError,
                "a persistence adapter built a #{aggregate.name} record from undecoded state " \
                "(#{state.keys.inspect}) — decode stored state through " \
                "Hecks::Ports::Persistence::StateCodec.decode before handing it to Runtime::Instance"
        end

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

        # Filled lazily under WRAPPERS_LOCK, one entry per adapter class —
        # a cache, deliberately mutable.
        WRAPPERS = {} # rubocop:disable Style/MutableConstant
        WRAPPERS_LOCK = Mutex.new

        # One wrapper module per adapter CLASS, built once: every public
        # instance method the class (and its ancestors below Object)
        # defines, each forwarding to `super` inside the boundary.
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

        # The caller's own block, re-wrapped to run OUTSIDE the boundary
        # whenever the adapter yields to it.
        def outside_block(block)
          return nil unless block

          proc { |*yielded, **yielded_kwargs, &inner| outside { block.call(*yielded, **yielded_kwargs, &inner) } }
        end
      end
    end
  end
end
