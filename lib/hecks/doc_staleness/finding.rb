module Hecks
  module DocStaleness
    # One stale citation: where it is, which class of staleness, and why.
    Finding = Struct.new(:path, :line, :kind, :reason) do
      # @return [String] `file:line: [kind] reason`
      def to_s = "#{path}:#{line}: [#{kind}] #{reason}"
    end
  end
end
