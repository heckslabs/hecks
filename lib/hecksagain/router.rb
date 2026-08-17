module Hecksagain
  # The public, project-wide dispatch door. It owns address resolution only;
  # each discovered Bluebook keeps its own runtime and persistence bindings.
  class Router
    class UnknownAddress < StandardError; end
    class WrongVerbKind < StandardError; end
    class NotBooted < StandardError; end
    class AmbiguousShortRoute < StandardError; end

    attr_reader :register

    def self.load(root) = new(Bluebook::ProjectLoader.load(root))

    # Install one project router for ordinary application calls. The explicit
    # `Router.load` API remains useful for tests and embedded hosts.
    def self.boot(root)
      router = load(root)
      router.install_namespace!
      @default = router
    end

    def self.default
      @default || raise(NotBooted, "no project router is booted — call Hecksagain::Router.boot(root) first")
    end

    def self.dispatch(address, **args) = default.dispatch(address, **args)
    def self.query(address, **args)    = default.query(address, **args)

    def initialize(register)
      @register = register
    end

    def available = register.entries.values

    def install_namespace! = NamespaceInstaller.new(self).install!

    def resolve(address)
      fqn = Fqn.parse(address)
      raise UnknownAddress, "router addresses require a realm: #{address.inspect}" unless fqn.realm

      register.fetch(fqn.to_s)
    rescue KeyError
      raise UnknownAddress, "no Bluebook route for #{address.inspect}"
    end

    def dispatch(address, **args)
      entry = resolve(address)
      raise WrongVerbKind, "#{address.inspect} names a query; use #query" unless entry.command?

      entry.dispatcher.dispatch(local_verb(entry), **args)
    end

    def query(address, **args)
      entry = resolve(address)
      raise WrongVerbKind, "#{address.inspect} names a command; use #dispatch" unless entry.query?

      entry.dispatcher.query(local_verb(entry), **args)
    end

    private

    def local_verb(entry)
      return "#{entry.fqn.domain}.#{entry.declared_verb}" unless entry.fqn.aggregate

      "#{entry.fqn.domain}::#{entry.fqn.aggregate}.#{entry.declared_verb}"
    end
  end
end

require_relative "router/namespace_installer"
