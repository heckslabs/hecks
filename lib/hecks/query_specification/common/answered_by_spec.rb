module Hecks
  module QuerySpecification
    module Common
      # The port whose bound adapter answers a query, in place of a scan over the aggregate's
      # records.
      AnsweredBySpec = Struct.new(:port, keyword_init: true) do
        def to_h = { port: port.to_s }
      end
    end
  end
end
