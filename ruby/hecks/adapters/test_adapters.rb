# Hecks::Adapters::TestAdapters
#
# [antibody-exempt: dream-study Phase 0h test seam — wires fixture/memory
#  adapters into a hecksagon at test boot. Retires when hecksagon
#  loading exposes a clean adapter-swap point and tests can declare the
#  swap declaratively in the bluebook test block (Phase 1+).]
#
# Test-time adapter swap. Given a hecksagon (or hecksagon-builder), flip
# every "live" adapter to its in-memory test counterpart so specs run
# in milliseconds instead of seconds :
#
#   :llm     → :fixture     (Hecks::Adapters::FixtureLlmAdapter)
#   :fs      → :memory      (no-op write, in-memory read)
#   :cadence → :test_clock  (manual tick advance)
#   :daemon  → :noop        (drop instead of spawn)
#
# The bluebook stays unchanged. Only the loaded hecksagon flips.
#
# Today's reality (as of 2026-05-02 / Phase 0h) : the production :llm,
# :cadence, and :daemon adapters DO NOT EXIST yet — those calls are
# made shell-side via $CLAUDE_BIN, $STOREHOUSE loop, etc. So the swap
# point this module exposes is forward-looking : it's the seam Phase
# 4-7 specs will hook into, and Phase 0h's job is to land the seam +
# prove it works against the only adapter that exists today (the
# :fixture LLM). The :fs/:cadence/:daemon swaps are stubbed as no-ops
# until the production adapters land ; the gap is documented in
# dream-study/test-gate/in_memory_adapter/gaps.md.
#
# Usage :
#
#   adapters = Hecks::Adapters::TestAdapters.new(
#     llm_fixture: "spec/fixtures/dream_responses.yaml"
#   )
#   adapters.llm.dream_pulse(cycle: 1, pulse: 1)["text_fr"]
#
#   # When a hecksagon-loading API exists :
#   #   hex = MyDomain.hecksagon
#   #   adapters.swap_into(hex)
#   #   # → hex now has :fixture wherever it had :llm
#
# The +swap_into(hecksagon)+ method is provided as a stub — see
# in_memory_adapter/gaps.md for the production path.
require_relative "fixture_llm_adapter"

module Hecks
  module Adapters
    class TestAdapters
      attr_reader :llm

      MAPPING = {
        llm: :fixture,
        fs: :memory,
        cadence: :test_clock,
        daemon: :noop,
      }.freeze

      def initialize(llm_fixture: nil, llm_data: nil)
        @llm = if llm_fixture
                 FixtureLlmAdapter.from_yaml(llm_fixture)
               elsif llm_data
                 FixtureLlmAdapter.new(llm_data)
               else
                 FixtureLlmAdapter.new({})
               end
      end

      # Returns the symbolic mapping. Stable enum so bluebook validators
      # (or future hecksagon parsers that want to know which adapters
      # have a documented test counterpart) can read this without
      # instantiating.
      def self.mapping
        MAPPING
      end

      # Swap-in stub. The hecksagon-side API to attach a per-adapter
      # override doesn't exist yet (the production :llm adapter doesn't
      # exist either). When it lands, this method walks the hecksagon's
      # io_adapters and replaces each kind in MAPPING with its test
      # counterpart, returning the modified hecksagon.
      #
      # Today this is a no-op that returns the input unchanged. Tests
      # that need an adapter swap inject the FixtureLlmAdapter directly
      # via dependency injection at the call site (see
      # in_memory_adapter/fixture_llm_spec.rb for the canonical shape).
      #
      # @param hecksagon [Object] a hecksagon IR or builder
      # @return [Object] the (today-unchanged) hecksagon
      def swap_into(hecksagon)
        # No-op until production adapters land. Documented gap.
        hecksagon
      end

      # Memoized empty stubs for the not-yet-implemented adapters. The
      # method names are stable so Phase 4-7 specs can write
      # `adapters.fs.read("...")` and have the call return the
      # documented sentinel rather than nil-explode.
      def fs
        @fs ||= MemoryFsStub.new
      end

      def cadence
        @cadence ||= TestClockStub.new
      end

      def daemon
        @daemon ||= NoopDaemonStub.new
      end

      # ── Stub shapes ────────────────────────────────────────────────
      # These are intentionally tiny ; they exist so tests have a
      # named seam to call, and so that when the real adapter lands the
      # production code can be a drop-in replacement.

      class MemoryFsStub
        def initialize
          @store = {}
        end

        def read(path)
          @store.fetch(path.to_s) { raise KeyError, "no in-memory file at #{path.inspect}" }
        end

        def write(path, data)
          @store[path.to_s] = data
          data
        end

        def exist?(path)
          @store.key?(path.to_s)
        end
      end

      class TestClockStub
        attr_reader :now_ts

        def initialize
          @now_ts = 0
        end

        def tick(seconds = 1)
          @now_ts += seconds
          self
        end
      end

      class NoopDaemonStub
        def spawn(*_args, **_kwargs)
          :noop
        end

        def kill(*_args)
          :noop
        end
      end
    end
  end
end
