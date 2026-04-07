# Hecks::Workshop::Playground::GemBootstrap
#
# Loads the domain into a Runtime. The domain IR is already in memory —
# InMemoryLoader generates source and evals it, no filesystem needed.
#
module Hecks
  class Workshop
    class Playground
      module GemBootstrap
        private

        def compile!
          Hecks.load_domain(@domain, force: true)
        end
      end
    end
  end
end
