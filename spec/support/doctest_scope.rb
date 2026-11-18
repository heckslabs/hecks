# The constant scope one guide's usage blocks run in.
#
# A boot installs its facade constants (`Lending`, `Book`) on Object through
# `Hecks::Namespace.install`, which leaves a name someone else already owns in place: a `Book`
# another spec in the same process left on Object would then stand in for the guide's own. Usage
# blocks therefore resolve constants through a fresh module, ahead of Object, into which each boot
# includes a module of its own facade constants. A usage block's own constants land in that module
# too, so a guide leaves none on Object either.
module Doctest
  class Scope
    # A name found nowhere goes to Object's own `const_missing`, as it would at top level, so a
    # usage block's inline bluebook still reaches the `ConstShim` resolver for its barewords.
    def initialize
      @module = Module.new
      @module.define_singleton_method(:const_missing) { |name| Object.const_missing(name) }
    end

    # A binding whose `self` is `host` and whose constant lookup starts in this scope.
    #
    # @param host [Object] the receiver usage blocks run against
    # @return [Binding]
    def binding_for(host)
      @module.module_eval("->(host) { host.instance_eval { binding } }", __FILE__, __LINE__).call(host)
    end

    # Puts a boot's top-level facade constants ahead of Object; a later boot's come first.
    #
    # @param dispatcher [Hecks::Runtime::Dispatcher] the booted dispatcher
    # @return [void]
    def admit(dispatcher)
      own = Module.new
      registry = dispatcher.registry
      registry.bluebooks.each_value do |bluebook|
        next if bluebook.namespace || ruby.attached_bluebook?(registry, bluebook)

        define(own, facade(dispatcher, bluebook), bluebook)
      end
      @module.include(own)
    end

    private

    def ruby = Hecks::Adapters::Driving::Ruby

    # A bluebook's module and the top-level shortcut of each of its aggregates.
    def define(own, declaration, bluebook)
      own.const_set(bluebook.name, declaration)
      bluebook.aggregates.map(&:hecks_name).reject { |name| name == bluebook.name }.each do |name|
        own.const_set(name, declaration.const_get(name, false))
      end
    end

    # The module the boot installed at `Object::<name>`, or, when `Namespace.install` left a
    # name someone else owns in place, a module built for this boot.
    def facade(dispatcher, bluebook)
      name = bluebook.name
      current = Object.const_get(name, false) if Object.const_defined?(name, false)
      return current if current && Hecks::Namespace::GENERATED[[Object, name]].equal?(current)

      ruby.bluebook_module(dispatcher, bluebook)
    end
  end
end
