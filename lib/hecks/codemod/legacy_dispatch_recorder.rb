# NOTHING HERE REQUIRES A GEM AT LOAD TIME — this file arrives through
# RUBYOPT, ahead of `bundler/setup`, and activating a default gem (json)
# that early makes Bundler refuse the Gemfile's own version. `json` is
# required on first write instead, by which point Bundler has resolved.
require_relative "../deprecation"

module Hecks
  module Codemod
    # THE OBSERVING HALF OF `bin/codemod_legacy_dispatch_args`. Loaded into a
    # test run through RUBYOPT (`bin/codemod_legacy_dispatch_args record --
    # <command>` arms it), it wraps `Runtime::Dispatcher#dispatch` and, for
    # every call that passed loose keyword facts, appends one JSON line
    # saying how that call's facts split between `to:` and `with:`.
    #
    # WHY RECORD INSTEAD OF READING SOURCE — loose keyword facts carry the
    # receiver's identity (`number: { value: "a1" }`, `id: order.id`) mixed
    # in with the command's facts, and which key is which is a property of
    # the target command's IR (its `identified_by`, its declared attributes,
    # the reference aliases `ReactionInvocation` accepts), not of the call's
    # text. The recorder asks the same `ReactionInvocation.build(explicit:
    # true)` split a policy's `with:` projection already uses, against the
    # real registry and the real values, then checks the strict `with:`
    # door would accept the result. The rewriter only touches a site whose
    # every observation agrees.
    #
    # Each line: site ("path:line", the caller's own line), verb, the loose
    # keys, `to_keys` (keys that carried receiver identity), `with_keys`
    # (declared facts — a key can be both), `slots` (which key fills which
    # part of the route, and whether its identity sat inside a one-field
    # hash), `strict` (the refusal class strict `with:` raises, or nil),
    # `outcome` ("ok" or the class the real dispatch raised),
    # `payload_keys` (every key the dispatch's own events carried), and
    # `unrewritable` when no split exists.
    module LegacyDispatchRecorder
      module_function

      def arm!(path)
        return install!(path) if defined?(Hecks::Runtime::Dispatcher)

        trace = TracePoint.new(:end) do |point|
          next unless point.self.is_a?(Module) && point.self.name == "Hecks::Runtime::Dispatcher"

          trace.disable
          install!(path)
        end
        trace.enable
      end

      def install!(path)
        Hecks::Runtime::Dispatcher.prepend(Wrap)
        Wrap.path = path
      end

      # Prepended onto Runtime::Dispatcher.
      module Wrap
        class << self
          attr_accessor :path
        end

        def dispatch(verb, to: nil, with: nil, saga_correlation: nil, **legacy_args)
          return super if legacy_args.empty?

          entry = LegacyDispatchRecorder.observe(self, verb, to, with, legacy_args)
          begin
            result = super
            entry[:outcome] = "ok"
            entry[:payload_keys] = LegacyDispatchRecorder.payload_keys(result)
            result
          rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised unchanged
            entry[:outcome] = e.class.name
            raise
          ensure
            LegacyDispatchRecorder.write(Wrap.path, entry)
          end
        end
      end

      # EVERY KEY THE DISPATCH'S OWN EVENTS CARRY. A loose fact reaches the
      # event payload whether the command declares it or not, and a policy
      # with no `with:` projection forwards that payload verbatim — so
      # moving a key out of the facts and into `to:` can silently empty a
      # field whatever reacts downstream needs. Recorded here so `plan_for`
      # can refuse exactly those sites; a real one (Banking's own
      # FreezeAccount -> ReviewOnFreeze -> AccountFreezeReview.Open, in
      # docs/implemented/reference/policy.md, whose own `# => true` on
      # `reaction_log.last[:delivered]` went false) is why this exists.
      def payload_keys(result)
        return [] unless result.respond_to?(:events)

        result.events.flat_map { |event| Hash(event.payload).keys.map(&:to_s) }.uniq
      rescue StandardError
        []
      end

      def observe(dispatcher, verb, to, with, legacy)
        frame = caller_locations(2).find { |location| Hecks::Deprecation.external?(location) }
        entry = { site: frame && "#{frame.absolute_path || frame.path}:#{frame.lineno}", verb: verb.to_s,
                  to_given: !to.nil?, keys: legacy.keys.map(&:to_s) }
        entry.merge(split(dispatcher.registry, verb, to, with, legacy))
      rescue StandardError => e
        entry.merge(unrewritable: "#{e.class}: #{e.message}")
      end

      def write(path, entry)
        require "json"
        File.open(path, "a") do |file|
          file.flock(File::LOCK_EX)
          file.puts(JSON.generate(entry))
        end
      end

      def split(registry, verb, to, with, legacy)
        return { unrewritable: "with: and loose keywords in the same call" } if with
        return { unrewritable: "a loose keyword that is not a Symbol" } unless legacy.keys.all?(Symbol)

        invocation = Hecks::Runtime::ReactionInvocation
        target = invocation.send(:resolve_target, registry, verb)

        if to
          return { to_keys: [], with_keys: legacy.keys.map(&:to_s), slots: [],
                   strict: strict(target, to, legacy) }
        end

        built = invocation.build(registry: registry, verb: verb, projected: legacy, explicit: true)
        route = built[:to]
        with_keys = legacy.keys.select { |key| built[:with].key?(key) }
        to_keys = route.nil? ? [] : legacy.keys.select { |key| consumed?(registry, verb, legacy, key, route) }
        slots = slots_for(route, to_keys, legacy)
        return slots if slots.is_a?(Hash)

        { to_keys: to_keys.map(&:to_s), with_keys: with_keys.map(&:to_s), slots: slots,
          strict: strict(target, route, legacy.slice(*with_keys)) }
      end

      # A key carried receiver identity when the route changes (or can no
      # longer be built) without it.
      def consumed?(registry, verb, legacy, key, route)
        Hecks::Runtime::ReactionInvocation.build(registry: registry, verb: verb,
                                                 projected: legacy.except(key), explicit: true)[:to] != route
      rescue StandardError
        true
      end

      # Which key fills each part of the route. Refuses anything a source
      # rewrite cannot spell as `to: <that key's expression>`: a composite
      # identity, two keys naming the same part, or a non-String identity
      # (`to:` takes only a String).
      def slots_for(route, to_keys, legacy)
        return [] if route.nil?

        parts = route.is_a?(Hash) ? [route[:aggregate], *route[:entities]] : [route]
        if to_keys.size != parts.size
          return { unrewritable: "identity spread over #{to_keys.size} keys for #{parts.size} route parts" }
        end

        to_keys.map do |key|
          form, inner, text = candidate(legacy[key])
          return { unrewritable: "#{key}: identity is not a String or a one-field hash of one" } unless text

          matches = parts.each_index.select { |index| parts[index].to_s == text }
          return { unrewritable: "#{key}: identity matches #{matches.size} route parts" } unless matches.one?

          { key: key.to_s, part: matches.first, form: form, inner: inner }
        end
      end

      def candidate(raw)
        return ["scalar", nil, raw] if raw.is_a?(String)
        return nil unless raw.is_a?(Hash) && raw.size == 1

        inner, value = raw.first
        ["hash", inner.to_s, value] if value.is_a?(String)
      end

      def strict(target, route, facts)
        Hecks::Runtime::Invocation.route(route, entity_depth: target.entities.size)
        Hecks::Runtime::Invocation.facts_for(target.command, with: facts, legacy: {})
        nil
      rescue StandardError => e
        e.class.name
      end
    end
  end
end

Hecks::Codemod::LegacyDispatchRecorder.arm!(ENV["HECKS_LEGACY_DISPATCH_RECORD"]) if ENV["HECKS_LEGACY_DISPATCH_RECORD"]
