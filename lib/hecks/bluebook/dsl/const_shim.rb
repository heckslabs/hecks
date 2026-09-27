module Hecks
  module Bluebook
    module DSL
      # A `const_missing` bridge: `.with(resolver) { ... }` lets bare, undeclared constants in a
      # DSL block resolve through the resolver instead of raising `NameError`.
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

        # Answers `::` on a bareword: a Symbol raises `TypeError` there, only a Module can chain.
        # A Module subclass so `Account::Debit` resolves; `to_s` matches the bare-name spelling.
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
          # Chains without limit: nothing here knows how deep a reference goes.
          # @param name [Symbol] the segment written after `::`
          # @return [Bluebook::DSL::ConstShim::ScopedConstant] a new constant for the longer path
          def const_missing(name) = ScopedConstant.for("#{@path}::#{name}")

          def to_s     = @path
          def to_sym   = @path.to_sym
          def inspect  = @path

          # Exposes the raw path so `==` can compare two scoped constants without `to_s`.
          #
          # @return [String] the `::`-joined path, such as `"Account::Debit"`
          def hecks_path = @path

          def ==(other) = other.is_a?(ScopedConstant) ? @path == other.hecks_path : @path.to_sym == other
          alias eql? ==
          def hash = @path.hash
        end

        # Scoped names are written as text, not constant paths (see `admits:`): once a facade
        # installs aggregate names as top-level constants, `Vocabulary` never reaches this hook.
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
