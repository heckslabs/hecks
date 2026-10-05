require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `.hecksagon` file's DSL block into a Hecksagon: a domain's adapter bindings,
      # attachments and subscriptions — wiring, not part of the bluebook.
      class HecksagonBuilder
        GRAMMAR_CONTEXT = "Hecksagon".freeze

        include WordGate

        class << self
          # The bind collector of the build running on this thread; thread-local, so a build
          # on another thread never sees it.
          #
          # @return [Array, nil] the binds the running build collects into
          def collector = Thread.current.thread_variable_get(:hecks_hecksagon_collector)

          # @param value [Array, nil] the binds the running build collects into
          def collector=(value)
            Thread.current.thread_variable_set(:hecks_hecksagon_collector, value)
          end

          # @return [String, nil] the name of the chapter whose hecksagon is being built
          def building = Thread.current.thread_variable_get(:hecks_hecksagon_building)

          # @param value [String, nil] the name of the chapter whose hecksagon is being built
          def building=(value)
            Thread.current.thread_variable_set(:hecks_hecksagon_building, value)
          end

          # @return [Hash, nil] the modules this thread's build has taken off `Hecks`
          def hidden_modules = Thread.current.thread_variable_get(:hecks_hecksagon_hidden)

          # @param value [Hash, nil] the modules this thread's build has taken off `Hecks`
          def hidden_modules=(value)
            Thread.current.thread_variable_set(:hecks_hecksagon_hidden, value)
          end
        end

        # Lets the Hecks chapter's own hecksagon spell its aggregates `Hecks::Operation`.
        #
        # While the chapter named Hecks builds its hecksagon, a missing constant on `Hecks` is
        # one of that chapter's aggregates; at any other time it is the ordinary `NameError`.
        #
        # A real module of the same name (`Hecks::Release`) would answer first, so
        # `HecksagonBuilder.build` takes each off `Hecks` while the block runs (see `shadowed`).
        # `attaches` loads whole chapters inside the block; the shadow lifts around each load
        # (see `with_real_modules`), so loaded code sees the real modules.
        module ChapterConstants
          # @param name [Symbol] the missing constant
          # @return [Bluebook::DSL::BindingProxy] a proxy for that aggregate while building
          def const_missing(name)
            return super unless HecksagonBuilder.building == "Hecks" && HecksagonBuilder.collector

            BindingProxy.new("Hecks::#{name}", HecksagonBuilder.collector)
          end
        end

        # The release that drops the deprecated spellings of `attaches`; independent of
        # `Hecks::Doors::REMOVAL`, which covers the older `Facade` aliases.
        REMOVAL = "3.3.0".freeze

        attr_reader :binds, :subscriptions, :attachments

        def initialize(domain)
          @domain             = domain
          @binds              = []
          @subscriptions      = []
          @attachments        = []
          @bounded            = false
          @translates         = []
        end

        # Marks this chapter as a bounded context; an attachment marks its chapter bounded too.
        # Must declare at least one `translates` ACL or boot refuses.
        def bounded
          @bounded = true
        end

        # Subscribes to an event from outside this domain's own bluebook.
        def subscribe(event) = @subscriptions << event.to_s

        # Attaches a chapter by name and loads it into the current registry, marked bounded.
        #
        # Without `from:` the name is a chapter the gem carries (a framework member such as
        # Governance, or a language chapter such as Deploy) with the ports and adapters it
        # ships. `from: :vendor` loads `vendor/embryonaut_bluebooks/<name>/bluebook` instead,
        # and is never a fallback for a misspelt gem name.
        #
        # @param name [String, Symbol] a gem chapter's name or a vendored package's directory name
        # @param from [Symbol, nil] `:vendor` for a vendored package, nil for a gem chapter
        # @raise [Runtime::WiringError] if the name is unknown, or `from:` names another source
        def attaches(name, from: nil)
          unless [nil, :vendor].include?(from)
            raise Runtime::WiringError,
                  "attaches #{name.to_s.inspect}, from: #{from.inspect} — `from:` takes only :vendor"
          end

          from == :vendor ? attach_vendored(name) : attach_gem(name)
        end

        # The deprecated spelling of `attaches "Name"` for a framework member.
        def uses_framework(name)
          deprecated_word("uses_framework", "attaches #{name.to_s.inspect}")
          @attachments << Attachment.new(name: name.to_s, source: :gem)
          self.class.with_real_modules { Hecks::Framework.load!(name) }
          Hecks.current_registry&.mark_bounded(name.to_s)
        end

        # The deprecated spelling of `attaches "name", from: :vendor`.
        def uses_embryonaut_bluebook(name)
          deprecated_word("uses_embryonaut_bluebook", "attaches #{name.to_s.inspect}, from: :vendor")
          attach_vendored(name)
        end

        # Declares a port at the hecksagon's root — the chapter as a whole, not one aggregate.
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
                        attachments: @attachments, bounded: @bounded, translates: @translates)
        end

        # Loads a chapter the gem carries and records it as attached from the gem.
        def attach_gem(name)
          require_relative "../../chapters"
          @attachments << Attachment.new(name: name.to_s, source: :gem)
          self.class.with_real_modules { Hecks::Chapters.attach!(name) }
          Hecks.current_registry&.mark_bounded(name.to_s)
        end
        private :attach_gem

        # Loads a vendored package and records it as attached from `vendor/`. The directory name
        # Pascal-cases to the chapter name (`"membership"` becomes `Membership`).
        def attach_vendored(name)
          @attachments << Attachment.new(name: name.to_s, source: :vendor)
          Hecks::EmbryonautBluebook.load!(name)
          Hecks.current_registry&.mark_bounded(Hecks::Naming.pascal(name.to_s))
        end
        private :attach_vendored

        # Tells the author that a word is going away.
        def deprecated_word(word, instead)
          warn "[hecks] `#{word}` is deprecated and is removed in #{REMOVAL}; use `#{instead}`"
        end
        private :deprecated_word

        # Records any verb the grammar doesn't own as a domain-wide default bind, e.g. bare
        # `persisted_by "Heki"` at the top of a block, applied unless an aggregate overrides it.
        def method_missing(verb, *args, **kwargs, &block)
          # Grammar words (like `port`) get first refusal via explicit dispatch; only when that's
          # not admitted does the open-ended `persisted_by`-style bind vocabulary below apply.
          result = word_gate_dispatch(verb, args, kwargs, block)
          return result unless result.equal?(WordGate::NOT_ADMITTED)

          return super unless args.first

          @binds << Bind.new(aggregate: nil, verb: verb.to_s, adapter: args.first.to_s, role: kwargs[:role]&.to_s)
          block&.call
          self
        end

        def respond_to_missing?(_name, _include_private = false) = true

        # Evaluates a `Hecks.hecksagon` block with bare `Domain::Aggregate` constants resolving to
        # bind-collecting proxies, and returns the wiring it declared.
        def self.build(domain, &block)
          builder  = new(domain)
          resolver = ->(name) { BindingProxy.namespace(name, builder.binds) }

          previous       = collector
          previous_name  = building
          self.collector = builder.binds
          self.building  = domain.to_s
          previous_hidden = hidden_modules
          hidden = previous_name == "Hecks" ? {} : shadowed(domain)
          self.hidden_modules = hidden.empty? ? previous_hidden : hidden
          begin
            ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          ensure
            restore_shadowed(hidden)
            self.hidden_modules = previous_hidden
            self.collector = previous
            self.building  = previous_name
          end

          builder.build
        end

        # Takes off `Hecks` each real module a chapter aggregate shares its name with, so the
        # name reaches `ChapterConstants#const_missing`. Only the chapter named Hecks has this
        # collision; a nested build of it leaves the outer build's shadows in place.
        #
        # @param domain [String, Symbol] the chapter whose hecksagon is being built
        # @return [Hash{Symbol => Object}] what was taken off, by name: the module, or the
        #   autoload path when the constant had not loaded yet
        def self.shadowed(domain)
          return {} unless domain.to_s == "Hecks"

          chapter = Hecks.current_registry&.bluebook("Hecks")
          names   = chapter ? chapter.aggregates.map { |aggregate| aggregate.hecks_name.to_sym } : []
          names.select { |name| Hecks.const_defined?(name, false) }.to_h do |name|
            pending = Hecks.autoload?(name)
            held    = pending ? [:autoload, pending] : [:module, Hecks.const_get(name, false)]
            Hecks.send(:remove_const, name)
            [name, held]
          end
        end

        # Runs the block with every module the running build shadowed back on `Hecks`, and a
        # missing `Hecks::X` an ordinary `NameError`, then shadows them again. A chapter loaded
        # from inside the hecksagon block is ordinary code, not the hecksagon's own vocabulary.
        # A no-op when nothing is shadowed.
        #
        # @yield the code that must see `Hecks`'s real modules
        # @return [Object] the block's result
        def self.with_real_modules
          hidden = hidden_modules
          return yield if hidden.nil? || hidden.empty?

          name = building
          restore_shadowed(hidden)
          self.building = nil
          begin
            yield
          ensure
            self.building = name
            hidden.replace(shadowed(name))
          end
        end

        # Puts back what `shadowed` took off.
        #
        # @param hidden [Hash{Symbol => Array}] `shadowed`'s answer
        # @return [void]
        def self.restore_shadowed(hidden)
          hidden.each do |name, (kind, held)|
            Hecks.send(:remove_const, name) if Hecks.const_defined?(name, false)
            kind == :autoload ? Hecks.autoload(name, held) : Hecks.const_set(name, held)
          end
        end
      end
    end
  end
end

Hecks.singleton_class.prepend(Hecks::Bluebook::DSL::HecksagonBuilder::ChapterConstants)
