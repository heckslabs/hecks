module Hecks
  # Gives a renamed constant's old name back, saying on standard error which name replaces it each
  # time the old one is used (ADR 0134). The old name stays until a release removes it.
  module RetiredNames
    module_function

    # @param owner [Module] the namespace that held the old constant
    # @param old [Symbol] the retired constant name
    # @param new [Symbol] the constant that replaces it, in the same namespace
    # @return [void]
    def constant(owner, old, new)
      owner.singleton_class.prepend(Module.new do
        define_method(:const_missing) do |name|
          next super(name) unless name == old

          warn "hecks: #{self.name}::#{old} is deprecated, use #{self.name}::#{new}"
          const_get(new)
        end
      end)
    end

    # @param owner [Module] the class or module that defines the new method
    # @param old [Symbol] the retired method name
    # @param new [Symbol] the method that replaces it
    # @return [void]
    def method_name(owner, old, new)
      owner.define_method(old) do |*args, **options, &block|
        warn "hecks: #{owner.name}##{old} is deprecated, use ##{new}"
        public_send(new, *args, **options, &block)
      end
    end
  end
end
