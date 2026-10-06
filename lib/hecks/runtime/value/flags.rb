module Hecks
  module Runtime
    class Value
      # The two thread-local flags that loosen validation for one caller on one thread: trusting
      # stored state, and the self-hosted judge's bootstrap. Extended into `Value` beside
      # `Coercion`.
      module Flags
        TRUSTED_LOAD_KEY = :hecks_trusting_stored_state

        # Marks the block as loading trusted, already-validated stored state, so
        # `validate!` skips its own checks for the block's duration.
        #
        # Thread-local, not a plain ivar, so two threads hydrating concurrently
        # never see or clear each other's flag.
        #
        # @yield the code that should see `trusting_stored_state?` true
        # @return [Object] the block's result
        def trusting_stored_state
          previous = Thread.current[TRUSTED_LOAD_KEY]
          Thread.current[TRUSTED_LOAD_KEY] = true
          yield
        ensure
          Thread.current[TRUSTED_LOAD_KEY] = previous
        end

        # Whether the current thread is inside a `trusting_stored_state` block.
        #
        # @return [Boolean] true if on this thread's own call stack
        def trusting_stored_state? = Thread.current[TRUSTED_LOAD_KEY] == true

        # `MetaValidator::Judge#send_to` walks a bluebook's own declarations through
        # the self-hosted "Bluebook" meta-domain, and its generic append handling
        # keys off a field's name ("position") rather than its declared type — so
        # the language's own grammar can hand this a raw Integer for a String-typed
        # meta field on every domain's first boot. This flag loosens
        # `check_scalar_shapes`'s String check only for that one caller; composite
        # shapes (Array/Hash) stay refused unconditionally, bootstrap or not, and no
        # real domain's own declared value objects are affected.
        BOOTSTRAP_KEY = :hecks_judge_bootstrapping

        # Marks the block as `MetaValidator::Judge#send_to`'s self-hosted bootstrap
        # dispatch, so `check_scalar_shapes` loosens its `String` check for the
        # block's duration.
        #
        # Thread-local, not a plain ivar, so two threads bootstrapping concurrently
        # never see or clear each other's flag.
        #
        # @yield the code that should see `judge_bootstrapping?` true
        # @return [Object] the block's result
        def judge_bootstrapping
          previous = Thread.current[BOOTSTRAP_KEY]
          Thread.current[BOOTSTRAP_KEY] = true
          yield
        ensure
          Thread.current[BOOTSTRAP_KEY] = previous
        end

        # Whether the current thread is inside a `judge_bootstrapping` block.
        #
        # @return [Boolean] true if on this thread's own call stack
        def judge_bootstrapping? = Thread.current[BOOTSTRAP_KEY] == true
      end
    end
  end
end
