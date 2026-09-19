module Hecks
  module Projections
    module Deploy
      # Plumbing `Lambda` and `Fargate` both need — VPC/subnet/security-group
      # resources, RDS/Aurora, `bastion.yaml`, and the era-minting/
      # translation Make recipes are the same problem (get a domain's own
      # Postgres instance stood up, and reachable for the one boot that
      # mints era 1) whichever compute target ships the domain's own code.
      #
      # Plain module functions, not a registered `Projector::Target` — this
      # has no `deployed_to(...)` block of its own to generate from, only
      # helpers the two real targets call with the facts they have already
      # resolved.
      module Shared
        module_function
      end
    end
  end
end
