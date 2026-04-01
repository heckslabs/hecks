# NodeHecks::NodeGenerator
#
# Top-level generator that coordinates all Node.js/TypeScript sub-generators.
# Delegates to ProjectGenerator which orchestrates aggregate, command,
# repository, and server generation.
#
#   gen = NodeGenerator.new(domain)
#   gen.generate("output/")  # => path to generated Node project
#
module NodeHecks
  class NodeGenerator
    def initialize(domain)
      @domain = domain
    end

    def generate(output_dir = ".")
      ProjectGenerator.new(@domain, output_dir: output_dir).generate
    end
  end
end
