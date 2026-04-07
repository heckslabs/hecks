# NodeHecks::RepositoryGenerator
#
# Generates a TypeScript in-memory repository class using a Map.
# Provides all(), find(), save(), and delete() methods.
#
#   gen = RepositoryGenerator.new(aggregate)
#   gen.generate  # => TypeScript source string
#
module NodeHecks
  class RepositoryGenerator
    include NodeUtils

    def initialize(aggregate)
      @agg = aggregate
    end

    def generate
      name = @agg.name
      lines = []
      lines << NodeUtils.ts_import(name, "../aggregates/#{NodeUtils.snake_case(name)}")
      lines << ""
      lines << "export class #{name}Repository {"
      lines << "  private store: Map<string, #{name}> = new Map();"
      lines << ""
      lines << "  all(): #{name}[] {"
      lines << "    return Array.from(this.store.values());"
      lines << "  }"
      lines << ""
      lines << "  find(id: string): #{name} | undefined {"
      lines << "    return this.store.get(id);"
      lines << "  }"
      lines << ""
      lines << "  save(entity: #{name}): void {"
      lines << "    this.store.set(entity.id, entity);"
      lines << "  }"
      lines << ""
      lines << "  delete(id: string): void {"
      lines << "    this.store.delete(id);"
      lines << "  }"
      lines << ""
      lines << "  count(): number {"
      lines << "    return this.store.size;"
      lines << "  }"
      lines << "}"
      NodeUtils.join_lines(lines)
    end
  end
end
