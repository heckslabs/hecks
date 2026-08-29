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

          def with(resolver)
            previous  = @resolver
            @resolver = resolver
            yield
          ensure
            @resolver = previous
          end

          def active? = !@resolver.nil?
        end

        # THE SCOPED-CONSTANT BRIDGE (ADR 0025, docs/dsl-work-slices.md's
        # S0b) — a Symbol cannot answer `::`, so `Account::Debit` and
        # `admits: Account::LedgerDirection` could never resolve past
        # their FIRST segment while `Account` returned a bare Symbol
        # (`resolver = ->(const) { const }`, bluebook_builder.rb's own
        # comment on why that was right for a BARE name): Ruby's `::`
        # operator raises `TypeError` on the returned value before any
        # DSL code runs at all, unless that value is itself a Module.
        #
        # A REAL `Module` subclass, not a decorated Symbol, for exactly
        # that reason — nothing else answers `::`. Every existing
        # consumer keeps working duck-typed, not because nothing
        # changed: `Attribute#spell`'s `type.is_a?(Module)` branch now
        # fires where it used to fall to `type.to_s`, and
        # `Naming.demodulise` (`path.split("::").last`) gives the
        # IDENTICAL string either way for a single segment — the two
        # branches were already equivalent for a name with no `::` in
        # it, which is every bareword before this.
        class ScopedConstant < Module
          def self.for(path) = new(path.to_s)

          def initialize(path)
            super()
            @path = path
          end

          # ONE MORE SEGMENT, the same way an unresolved const anywhere
          # else does — `Account::Debit::Anything` keeps chaining rather
          # than refusing, since nothing here knows how deep a reference
          # is meant to go; the DSL keyword that finally reads `.to_s`
          # is the one place that does.
          def const_missing(name) = ScopedConstant.for("#{@path}::#{name}")

          def to_s     = @path
          def to_sym   = @path.to_sym
          def inspect  = @path
          def hecks_path = @path

          def ==(other) = other.is_a?(ScopedConstant) ? @path == other.hecks_path : @path.to_sym == other
          alias eql? ==
          def hash = @path.hash
        end

        # A SCOPED NAME IS WRITTEN AS TEXT, NOT AS A CONSTANT PATH — see the
        # note on `admits:` in AttributeCollector. A resolver returning a
        # Module (so that `Vocabulary::QueryComparator` reaches a second
        # `const_missing`) was tried and cannot be made to hold : `Facade::
        # Surface` installs EVERY aggregate name as a top-level constant, so
        # once any facade is built, `Vocabulary` resolves to that real module
        # and never reaches this hook at all. A spelling that works only
        # before a facade exists is worse than one that always works.
        module Hook
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
