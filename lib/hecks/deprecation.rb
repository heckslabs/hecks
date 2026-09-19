# Deprecation warnings this gem raises about its own API. Not a singleton
# method on `Hecks` itself: the self-hosted language declares every word
# that module answers (spec/syntax_conformance_spec.rb), and a warning
# about an old call shape is not a word of the language — callers name
# `Hecks::Deprecation.call` in full.
module Hecks
  # One warning per call site, naming the caller's line — never a line
  # inside this gem. A deprecated shape usually reaches the runtime through
  # a forwarding door (`Hecks::Router`, a namespace shortcut, a
  # `RemoteDispatcher`), so the site reported is the first frame outside
  # `lib/hecks`, which is the line a reader can actually change.
  #
  #   Hecks::Deprecation.call(:legacy_dispatch_args, "pass facts in with:")
  #   # warns once: "spec/foo_spec.rb:12: warning: pass facts in with:"
  #
  # Per key, in this order:
  #   `allowing(key) { ... }`  — suppressed for the block, this thread only
  #                              (the spec that tests a deprecation itself)
  #   `raise_on!(key)`         — raises `Hecks::Deprecation::Error` (the
  #                              test suite, so no spec reintroduces it);
  #                              with a block, only where the block says so,
  #                              given the site, so a suite can raise on
  #                              new sites while a known worklist warns
  #   HECKS_SILENCE_DEPRECATIONS=1 — silent
  #   otherwise                — `Kernel#warn`, once per key and call site
  module Deprecation
    class Error < StandardError
    end

    LIB_ROOT = File.expand_path(__dir__)
    LIB_ENTRY = File.expand_path("../hecks.rb", __dir__)

    EVERYWHERE = ->(_site) { true }

    @seen = {}
    @raising = {}
    @mutex = Mutex.new

    class << self
      # { key => where it raises instead of warning }.
      attr_reader :raising

      # Arms one or more deprecation keys to raise `Error` instead of warning.
      #
      # @param keys [Array<Symbol>] deprecation keys to arm
      # @yield [site] optional predicate; without a block every site raises
      # @yieldparam site [String] the "path:line" of the deprecated call
      # @yieldreturn [Boolean] whether that site should raise rather than warn
      # @return [Array<Symbol>] `keys`
      def raise_on!(*keys, &where)
        keys.each { |key| @raising[key] = where || EVERYWHERE }
        keys
      end

      # Warns once about a deprecated call, or raises where `raise_on!` has armed it.
      #
      # @param key [Symbol] the deprecation being reported
      # @param message [String] the warning (or exception) text
      # @return [void]
      # @raise [Error] if `key` is armed via `raise_on!` and, when armed with a block,
      #   the call site matches it
      def call(key, message)
        return if allowed?(key)

        uplevel, site = external_frame
        raise Error, "#{site}: #{message}" if @raising[key]&.call(site)
        return if ENV["HECKS_SILENCE_DEPRECATIONS"] == "1"
        return unless first_sighting?(key, site)

        Kernel.warn(message, uplevel: uplevel)
      end

      # Suppresses one deprecation key for the duration of the block, on this
      # thread only.
      #
      # @param key [Symbol] the deprecation key to suppress
      # @yield the code that may trigger `key`'s deprecation warning
      # @return [Object] the block's result
      def allowing(key)
        allowed = Thread.current[:hecks_allowed_deprecations] ||= []
        allowed.push(key)
        yield
      ensure
        allowed.pop
      end

      # Forgets every site already warned about — for specs only.
      #
      # @return [void]
      def reset! = @mutex.synchronize { @seen.clear }

      # Tells whether `frame` lies outside this gem's own `lib/hecks` and
      # `hecks.rb` entrypoint — the frame a deprecation warning should blame.
      #
      # @param frame [Thread::Backtrace::Location] a caller frame
      # @return [Boolean]
      def external?(frame)
        path = frame.absolute_path || frame.path
        !(path.start_with?("<internal:") || path == LIB_ENTRY || path.start_with?("#{LIB_ROOT}/"))
      end

      private

      def allowed?(key) = Array(Thread.current[:hecks_allowed_deprecations]).include?(key)

      def first_sighting?(key, site)
        @mutex.synchronize { @seen.key?([key, site]) ? false : (@seen[[key, site]] = true) }
      end

      # `uplevel:` counts from the frame that calls `Kernel.warn` — `call`,
      # this method's caller — and `caller_locations(1)` starts at that
      # same frame, so the index found here is the uplevel to pass.
      def external_frame
        frames = caller_locations(1)
        index = frames.index { |frame| external?(frame) } || (frames.size - 1)
        [index, "#{frames[index].path}:#{frames[index].lineno}"]
      end
    end
  end
end
