module Hecks
  # The public, project-wide dispatch door. It owns address resolution only;
  # each discovered Bluebook keeps its own runtime and persistence bindings.
  class Router
    class UnknownAddress < StandardError; end
    class WrongVerbKind < StandardError; end
    class NotBooted < StandardError; end
    class AmbiguousShortRoute < StandardError; end

    attr_reader :register

    # Loads a project's bluebooks and builds a router over them, without
    # installing any Ruby namespace shortcuts.
    #
    # @param root [String] project root to discover bluebooks under
    # @return [Router] the built router
    def self.load(root) = new(Bluebook::ProjectLoader.load(root))

    # Install one project router for ordinary application calls. The explicit
    # `Router.load` API remains useful for tests and embedded hosts.
    #
    # @param root [String] project root to discover bluebooks under
    # @return [Router] the booted router, also stored as `.default`
    def self.boot(root)
      router = load(root)
      router.install_namespace!
      @default = router
    end

    # The process-wide router `.boot` installed.
    #
    # @return [Router] the router `.boot` installed
    # @raise [NotBooted] if `.boot` has not been called yet
    def self.default
      @default || raise(NotBooted, "no project router is booted — call Hecks::Router.boot(root) first")
    end

    # (see #dispatch)
    def self.dispatch(address, **args) = default.dispatch(address, **args)
    # (see #query)
    def self.query(address, **args)    = default.query(address, **args)

    # @param register [Bluebook::ProjectRegister, Bluebook::ProjectLoader] the FQN
    #   catalogue to resolve addresses against
    def initialize(register)
      @register = register
    end

    # Lists every routed FQN entry.
    #
    # @return [Array<Bluebook::ProjectRegister::Entry>] every routed FQN entry
    def available = register.entries.values

    # Installs Ruby namespace constants and shortcut methods for every
    # current-version route.
    #
    # @return [NamespaceInstaller] the installer that performed the install
    def install_namespace! = NamespaceInstaller.new(self).install!

    # Resolves an address to its routed FQN entry.
    #
    # @param address [String] a fully-qualified command or query address, realm included
    # @return [Bluebook::ProjectRegister::Entry] the routed entry
    # @raise [UnknownAddress] if `address` has no realm, or names no known route
    # @raise [Fqn::Invalid] if `address` is not a well-formed FQN
    def resolve(address)
      fqn = Fqn.parse(address)
      raise UnknownAddress, "router addresses require a realm: #{address.inspect}" unless fqn.realm

      register.fetch(fqn.to_s)
    rescue KeyError
      raise UnknownAddress, "no Bluebook route for #{address.inspect}"
    end

    # Dispatches a command to its resolved aggregate.
    #
    # @param address [String] a fully-qualified command address, realm included
    # @param args [Hash] command facts, plus the dispatcher's optional `:to`, `:with`,
    #   and `:saga_correlation` keys
    # @return [Runtime::Dispatcher::Result] the dispatch result
    # @raise [UnknownAddress] if `address` has no realm, or names no known route
    # @raise [WrongVerbKind] if `address` names a query
    # @raise [Runtime::UnknownVerb] if the resolved verb names something undeclared
    # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the domain refuses
    #   the call
    # @raise [Runtime::StaleWrite] if concurrent writers beat this one through every retry
    # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
    def dispatch(address, **args)
      entry = resolve(address)
      raise WrongVerbKind, "#{address.inspect} names a query; use #query" unless entry.command?

      entry.dispatcher.dispatch_flat(local_verb(entry), args)
    end

    # Queries a resolved aggregate, entity, or read model.
    #
    # @param address [String] a fully-qualified query address, realm included
    # @param args [Hash{Symbol => Object}] the query's declared arguments
    # @return [Array<Hash>] one row Hash per match; see `Runtime::Dispatcher#query`
    #   for the exact shape per address kind
    # @raise [UnknownAddress] if `address` has no realm, or names no known route
    # @raise [WrongVerbKind] if `address` names a command
    # @raise [Runtime::UnknownVerb] if the resolved verb names something undeclared
    # @raise [Runtime::NotFound] if a read model's root reference names no record
    # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
    # @raise [KeyError] if a rooted read model is asked without its reference argument
    # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
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
