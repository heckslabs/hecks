# Gives every example group its own facade constants.
#
# A boot installs each chapter and aggregate as a top-level constant (`Widgets`, `Item`) through
# `Hecks::Namespace.install` and nothing removes them, so a group that boots a fixture domain
# leaves its names visible to whichever group runs next. A later group then resolves `Widgets` to
# the earlier group's module instead of failing or reaching its own, which makes the result depend
# on the random order. After each group this puts back what `Hecks::Namespace` held before it:
# constants the group installed are removed, and ones it replaced are restored.
module FacadeConstantIsolation
  # Records the facade constants installed right now.
  #
  # @return [Hash{Array => Module}] `[container, name]` to the installed module
  def self.snapshot = Hecks::Namespace::GENERATED.dup

  # Returns the installed facade constants to `before`.
  #
  # @param before [Hash{Array => Module}] a value from `snapshot`
  # @return [void]
  def self.restore(before)
    uninstall_added(before)
    reinstall_missing(before)
  end

  # @param before [Hash{Array => Module}] a value from `snapshot`
  # @return [void]
  def self.uninstall_added(before)
    Hecks::Namespace::GENERATED.to_a.each do |(container, name), value|
      next if before[[container, name]].equal?(value)

      remove_constant(container, name)
      Hecks::Namespace::GENERATED.delete([container, name])
    end
  end
  private_class_method :uninstall_added

  # @param before [Hash{Array => Module}] a value from `snapshot`
  # @return [void]
  def self.reinstall_missing(before)
    before.each do |(container, name), value|
      next if Hecks::Namespace::GENERATED[[container, name]].equal?(value)

      remove_constant(container, name)
      container.const_set(name, value)
      Hecks::Namespace::GENERATED[[container, name]] = value
    end
  end
  private_class_method :reinstall_missing

  # @param container [Module] the module holding the constant
  # @param name [Symbol] the constant's name
  # @return [void]
  def self.remove_constant(container, name)
    container.send(:remove_const, name) if container.const_defined?(name, false) # rubocop:disable RSpec/RemoveConst
  end
  private_class_method :remove_constant
end

RSpec.configure do |config|
  config.before(:context) { @facade_constants_before = FacadeConstantIsolation.snapshot }
  config.after(:context)  { FacadeConstantIsolation.restore(@facade_constants_before) }
end
