module Hecks
  module Bluebook
    module DSL
      # A global (Object-level, via `Hook` prepended below) `const_missing`
      # bridge — `.with(resolver) { ... }` installs a resolver for the
      # dynamic extent of a block, so a bare, not-yet-declared constant
      # inside a DSL block (a bareword type, `Domain::Aggregate`, ...)
      # resolves to whatever that DSL context needs (a name, a
      # `BindingProxy`, a `ScopedConstant`) instead of raising `NameError`.
      module ConstShim
        class << self
          attr_accessor :resolver

          # Installs a resolver for the duration of a block, restoring the earlier one afterwards
          # even if the block raises.
          #
          # @param resolver [#call] called with the missing constant's name as a Symbol; whatever
          #   it returns is what the bare constant evaluates to
          # @yield the DSL code whose undeclared constants the resolver should answer
          # @yieldreturn [Object] any value; it becomes this method's result
          # @return [Object] whatever the block returns
          def with(resolver)
            previous  = @resolver
            @resolver = resolver
            yield
          ensure
            @resolver = previous
          end

          # Reports whether a resolver is installed, meaning code is running inside a DSL block.
          #
          # @return [Boolean] true inside a `with` block, or after `resolver=` set one directly
          def active? = !@resolver.nil?
        end

        # The scoped-constant bridge (ADR 0025, docs/dsl-work-slices.md's
        # S0b) — a Symbol cannot answer `::`, so `Account::Debit` and
        # `admits: Account::LedgerDirection` could never resolve past
        # their first segment while `Account` returned a bare Symbol
        # (`resolver = ->(const) { const }`, bluebook_builder.rb's own
        # comment on why that was right for a bare name): Ruby's `::`
        # operator raises `TypeError` on the returned value before any
        # DSL code runs at all, unless that value is itself a Module.
        #
        # A real `Module` subclass, not a decorated Symbol, for exactly
        # that reason — nothing else answers `::`. Every consumer of a
        # bareword type keeps working duck-typed: `Attribute#spell`'s
        # `type.is_a?(Module)` branch fires for one of these where a
        # bare Symbol falls to `type.to_s`, and `Naming.demodulise`
        # (`path.split("::").last`) gives the identical string either
        # way for a single segment — the two branches are equivalent
        # for a name with no `::` in it, which is every unscoped
        # bareword.
        class ScopedConstant < Module
          # Wraps a constant path, the form a `ConstShim` resolver hands back for a bareword.
          #
          # @param path [Symbol, String] one segment such as `:Account`, or a `::`-joined path
          # @return [Bluebook::DSL::ConstShim::ScopedConstant] a module standing in for that path
          def self.for(path) = new(path.to_s)

          # @param path [String] the constant path this module stands in for
          def initialize(path)
            super()
            @path = path
          end

          # Extends the path by one segment, so `Account::Debit` resolves past `Account`.
          #
          # One more segment, the same way an unresolved const anywhere
          # else does — `Account::Debit::Anything` keeps chaining rather
          # than refusing, since nothing here knows how deep a reference
          # is meant to go; the DSL keyword that finally reads `.to_s`
          # is the one place that does.
          #
          # @param name [Symbol] the segment written after `::`
          # @return [Bluebook::DSL::ConstShim::ScopedConstant] a new constant for the longer path
          def const_missing(name) = ScopedConstant.for("#{@path}::#{name}")

          def to_s     = @path
          def to_sym   = @path.to_sym
          def inspect  = @path

          # Exposes the raw path under a name no ordinary `Module` answers, so `==` can compare
          # two scoped constants without going through `to_s`.
          #
          # @return [String] the `::`-joined path, such as `"Account::Debit"`
          def hecks_path = @path

          def ==(other) = other.is_a?(ScopedConstant) ? @path == other.hecks_path : @path.to_sym == other
          alias eql? ==
          def hash = @path.hash
        end

        # A scoped name is written as text, not as a constant path — see the
        # note on `admits:` in AttributeCollector. A resolver returning a
        # Module (so that `Vocabulary::QueryComparator` reaches a second
        # `const_missing`) was tried and cannot be made to hold : `Facade::
        # Surface` installs every aggregate name as a top-level constant, so
        # once any facade is built, `Vocabulary` resolves to that real module
        # and never reaches this hook at all. A spelling that works only
        # before a facade exists is worse than one that always works.
        module Hook
          # Answers an undeclared top-level constant from the active resolver, if there is one.
          #
          # @param name [Symbol] the missing constant's name
          # @return [Object] whatever the active resolver returns for `name`
          # @raise [NameError] if no resolver is installed, as Ruby raises for any unknown constant
          def const_missing(name)
            resolver = ConstShim.resolver
            resolver ? resolver.call(name) : super
          end
        end
      end
    end
  end
end

Object.singleton_class.prepend(Hecks::Bluebook::DSL::ConstShim::Hook)
