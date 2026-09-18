# Deprecation warnings this gem raises about its own API — see
# Hecks::Deprecation below.
module Hecks
  # ONE WARNING PER CALL SITE, NAMING THE CALLER'S LINE — never a line
  # inside this gem. A deprecated shape usually reaches the runtime through
  # a forwarding door (`Hecks::Router`, a namespace shortcut, a
  # `RemoteDispatcher`), so the site reported is the first frame OUTSIDE
  # `lib/hecks`, which is the line a reader can actually change.
  #
  #   Hecks.deprecate(:legacy_dispatch_args, "pass facts in with:")
  #   # warns once: "spec/foo_spec.rb:12: warning: pass facts in with:"
  #
  # Per key, in this order:
  #   `allowing(key) { ... }`  — suppressed for the block, this thread only
  #                              (the spec that tests a deprecation itself)
  #   `raise_on!(key)`         — raises `Hecks::Deprecation::Error` (the
  #                              test suite, so no spec reintroduces it);
  #                              with a block, only where the block says so,
  #                              given the site, so a suite can raise on
  #                              NEW sites while a known worklist warns
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

      def raise_on!(*keys, &where)
        keys.each { |key| @raising[key] = where || EVERYWHERE }
        keys
      end

      def call(key, message)
        return if allowed?(key)

        uplevel, site = external_frame
        raise Error, "#{site}: #{message}" if @raising[key]&.call(site)
        return if ENV["HECKS_SILENCE_DEPRECATIONS"] == "1"
        return unless first_sighting?(key, site)

        Kernel.warn(message, uplevel: uplevel)
      end

      def allowing(key)
        allowed = Thread.current[:hecks_allowed_deprecations] ||= []
        allowed.push(key)
        yield
      ensure
        allowed.pop
      end

      # Forget every site already warned about — for specs only.
      def reset! = @mutex.synchronize { @seen.clear }

      # The first caller frame outside this gem — where a deprecated call
      # was written.
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

  def self.deprecate(key, message) = Deprecation.call(key, message)
end
