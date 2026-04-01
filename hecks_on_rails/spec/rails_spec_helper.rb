# spec_helper for hecks_on_rails
#
# Stubs Rails::Railtie before requiring active_hecks so tests never
# need the railties gem. Captures registered initializer blocks so
# railtie_spec can replay them.
#
module Rails
  class Railtie
    def self.generators(&block); end

    def self.initializer(name, **opts, &block)
      (@_initializers ||= []) << { name: name, opts: opts, block: block }
    end

    def self.rake_tasks(&block); end
    def self._initializers; @_initializers ||= []; end
  end
end

require "hecks"
require "active_hecks"
