require_relative "word_gate"
require_relative "hecksagon_builder/chapter_scope"
module Hecks
  module Bluebook
    module DSL
      # Parses a `.hecksagon` file's DSL block into a Hecksagon: a domain's adapter bindings,
      # attachments and subscriptions — wiring, not part of the bluebook.
      class HecksagonBuilder
        GRAMMAR_CONTEXT = "Hecksagon".freeze

        include WordGate
        extend ChapterScope

        # Lets the Hecks bluebook's own hecksagon spell its aggregates `Hecks::Operation`.
        #
        # While the bluebook named Hecks builds its hecksagon, a missing constant on `Hecks` is
        # one of that bluebook's aggregates; at any other time it is the ordinary `NameError`.
        #
        # A real module of the same name (`Hecks::Release`) would answer first, so
        # `HecksagonBuilder.build` takes each off `Hecks` while the block runs (see `shadowed`).
        # `attaches` loads whole bluebooks inside the block; the shadow lifts around each load
        # (see `with_real_modules`), so loaded code sees the real modules.
        module ChapterConstants
          # @param name [Symbol] the missing constant
          # @return [Bluebook::DSL::BindingProxy] a proxy for that aggregate while building
          def const_missing(name)
            return super unless HecksagonBuilder.building == "Hecks" && HecksagonBuilder.collector

            BindingProxy.new("Hecks::#{name}", HecksagonBuilder.collector)
          end
        end

        # Spellings of `attaches` that 3.4.0 removed, each with the form that replaces it. They
        # are refused by name so an old hecksagon fails loudly, never as a stray default bind.
        REMOVED_WORDS = {
          "uses_framework"           => ->(name) { "attaches #{name.to_s.inspect}" },
          "uses_embryonaut_bluebook" => ->(name) { "attaches #{name.to_s.inspect}, from: :vendor" }
        }.freeze

        # Words older hecksagons carry that no grammar word or port defines and nothing reads. They
        # are refused by name so the file fails at the line, not later as an unknown adapter.
        RETIRED_WORDS = %w[capabilities concerns annotate].freeze

        attr_reader :binds, :subscriptions, :attachments

        def initialize(domain)
          @domain             = domain
          @binds              = []
          @subscriptions      = []
          @attachments        = []
          @driving            = []
          @bounded            = false
          @translates         = []
        end

        # Marks this bluebook as a bounded context; an attachment marks its bluebook bounded too.
        # Must declare at least one `translates` ACL or boot refuses.
        def bounded
          @bounded = true
        end

        # Subscribes to an event from outside this domain's own bluebook.
        def subscribe(event) = @subscriptions << event.to_s

        # Admits a driving adapter (`Ruby`, `Cli`, `Json` or `Mcp`) to reach this domain. Once any
        # is declared, the adapters left out refuse the domain; none declared leaves it open.
        #
        # @param adapter [String, Symbol] the adapter's name
        # @return [void]
        def driven_by(adapter) = @driving << adapter.to_s

        # Attaches a bluebook by name and loads it into the current registry, marked bounded.
        #
        # Without `from:` the name is a bluebook the gem carries (a framework member such as
        # Governance, or a language bluebook such as Deploy) with the ports and adapters it
        # ships. `from: :vendor` loads `vendor/embryonaut_bluebooks/<name>/bluebook` instead,
        # and is never a fallback for a misspelt gem name.
        #
        # @param name [String, Symbol] a gem bluebook's name or a vendored package's directory name
        # @param from [Symbol, nil] `:vendor` for a vendored package, nil for a gem bluebook
        # @raise [Runtime::WiringError] if the name is unknown, or `from:` names another source
        def attaches(name, from: nil)
          unless [nil, :vendor].include?(from)
            raise Runtime::WiringError,
                  "attaches #{name.to_s.inspect}, from: #{from.inspect} — `from:` takes only :vendor"
          end

          from == :vendor ? attach_vendored(name) : attach_gem(name)
        end

        # Declares a port at the hecksagon's root — the bluebook as a whole, not one aggregate.
        def port_impl(name, &block)
          bluebook_ir = Hecks.current_registry.bluebook(@domain) or
            raise Malformed, "#{@domain} declares no such bluebook — a port needs one to belong to"

          # Swaps the active ConstShim resolver to plain passthrough — without it a bare constant
          # inside `reference_to`/`attribute` would resolve to a BindingProxy instead of a name.
          built = ConstShim.with(->(const) { const }) { DomainPortBuilder.build(name, &block) }

          # A verb-shaped port is a plain `Port`, registered like `Hecks.port`'s top-level method,
          # not attached to this bluebook's IR the way an operations-shaped `DomainPort` is.
          return Hecks.current_registry.add_port(built) if built.is_a?(Port)

          bluebook_ir.add_port(built)
        end

        # A cross-domain reaction, built as the same `Policy` an in-bluebook `policy` block would.
        # Must be a block — the eager const resolver here can't handle multi-segment references.
        def translates(name, &block)
          bluebook_ir = Hecks.current_registry.bluebook(@domain) or
            raise Malformed, "#{@domain} declares no such bluebook — translates needs one to attach its reaction to"

          # Same resolver `policy` blocks use for `on`/`trigger` — a ScopedConstant, not the bare
          # passthrough `port_impl` swaps to, since these take multi-segment references.
          resolver = ->(const) { ConstShim::ScopedConstant.for(const) }
          built = ConstShim.with(resolver) { PolicyBuilder.build(name, &block) }

          @translates << name.to_s
          bluebook_ir.add_policy(built)
        end

        # Assembles the collected binds, subscriptions and attachments into a `Hecksagon`.
        # No ungoverned-role check here — it runs once on the merged result at verify! time.
        def build
          Hecksagon.new(domain: @domain, binds: @binds, subscriptions: @subscriptions,
                        attachments: @attachments, bounded: @bounded, translates: @translates,
                        driving: @driving)
        end

        # Loads a bluebook the gem carries and records it as attached from the gem.
        def attach_gem(name)
          require_relative "../../framework_bluebooks"
          @attachments << Attachment.new(name: name.to_s, source: :gem)
          self.class.with_real_modules { Hecks::FrameworkBluebooks.attach!(name) }
          Hecks.current_registry&.mark_bounded(name.to_s)
        end
        private :attach_gem

        # Loads a vendored package and records it as attached from `vendor/`, under the bluebook
        # its bluebook declares: `"document"` attaches `Documents`.
        def attach_vendored(name)
          chapter = Hecks::EmbryonautBluebook.load!(name)
          @attachments << Attachment.new(name: name.to_s, source: :vendor, chapter: chapter)
          Hecks.current_registry&.mark_bounded(chapter)
        end
        private :attach_vendored

        # Records any verb the grammar doesn't own as a domain-wide default bind, e.g. bare
        # `persisted_by "Heki"` at the top of a block, applied unless an aggregate overrides it.
        def method_missing(verb, *args, **kwargs, &block)
          refuse_removed_word(verb, args.first)

          # Grammar words (like `port`) get first refusal via explicit dispatch; only when that's
          # not admitted does the open-ended `persisted_by`-style bind vocabulary below apply.
          result = word_gate_dispatch(verb, args, kwargs, block)
          return result unless result.equal?(WordGate::NOT_ADMITTED)

          return super unless args.first

          @binds << Bind.new(aggregate: nil, verb: verb.to_s, adapter: args.first.to_s, role: kwargs[:role]&.to_s)
          block&.call
          self
        end

        # Raises for a word 3.4.0 removed, naming the spelling that replaces it, and for a retired
        # word that has no replacement.
        #
        # @param verb [Symbol] the word the hecksagon block called
        # @param name [Object, nil] its first argument, echoed into the replacement
        # @raise [Malformed] when the word is one of `REMOVED_WORDS` or `RETIRED_WORDS`
        def refuse_removed_word(verb, name)
          instead = REMOVED_WORDS[verb.to_s]
          raise Malformed, "`#{verb}` was removed in 3.4.0; use `#{instead.call(name)}`" if instead
          return unless RETIRED_WORDS.include?(verb.to_s)

          raise Malformed, "`#{verb}` is not a hecksagon word and nothing reads it; delete the line"
        end
        private :refuse_removed_word

        def respond_to_missing?(_name, _include_private = false) = true

        # Evaluates a `Hecks.hecksagon` block with bare `Domain::Aggregate` constants resolving to
        # bind-collecting proxies, and returns the wiring it declared.
        def self.build(domain, &block)
          builder  = new(domain)
          resolver = ->(name) { BindingProxy.namespace(name, builder.binds) }

          scoped_to(domain, builder.binds) { ConstShim.with(resolver) { builder.instance_eval(&block) } if block }

          builder.build
        end
      end
    end
  end
end

Hecks.singleton_class.prepend(Hecks::Bluebook::DSL::HecksagonBuilder::ChapterConstants)
