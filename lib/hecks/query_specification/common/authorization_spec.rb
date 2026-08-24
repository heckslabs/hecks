module Hecks
  module QuerySpecification
    module Common
      AuthorizationSpec = Struct.new(:policy, :tenant, keyword_init: true) do
        def to_h = { policy: policy.to_s, tenant: tenant && tenant.to_s }
      end
    end
  end
end
