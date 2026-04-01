# Hecks::ThreadContextMethods
#
# Thread-local tenant and actor context.
# Extracted from the Hecks module.
#
module Hecks
  module ThreadContextMethods
    def tenant
      Thread.current[:hecks_tenant]
    end

    def tenant=(tenant_id)
      Thread.current[:hecks_tenant] = tenant_id&.to_s
    end

    def with_tenant(tenant_id)
      old = Thread.current[:hecks_tenant]
      Thread.current[:hecks_tenant] = tenant_id.to_s
      yield
    ensure
      Thread.current[:hecks_tenant] = old
    end

    def actor
      Thread.current[:hecks_actor]
    end

    def actor=(actor)
      Thread.current[:hecks_actor] = actor
    end

    def with_actor(actor)
      old = Thread.current[:hecks_actor]
      Thread.current[:hecks_actor] = actor
      yield
    ensure
      Thread.current[:hecks_actor] = old
    end

    def current_user
      Thread.current[:hecks_current_user]
    end

    def current_user=(user)
      Thread.current[:hecks_current_user] = user
    end

    def with_user(user)
      old = Thread.current[:hecks_current_user]
      Thread.current[:hecks_current_user] = user
      yield
    ensure
      Thread.current[:hecks_current_user] = old
    end
  end
end
