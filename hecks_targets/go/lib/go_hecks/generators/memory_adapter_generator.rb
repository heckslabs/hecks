# GoHecks::MemoryAdapterGenerator
#
# Generates a Go in-memory repository using sync.RWMutex + map.
# Implements the aggregate's repository interface.
#
module GoHecks
  class MemoryAdapterGenerator
    include GoUtils

    def initialize(aggregate, package:, domain_package:, domain_alias: nil)
      @agg = aggregate
      @package = package
      @domain_package = domain_package
      @domain_alias = domain_alias
    end

    def generate
      agg = @agg.name
      var = GoUtils.camel_case(agg)

      lines = []
      lines << "package #{@package}"
      lines << ""
      lines << "import ("
      lines << "\t\"sync\""
      if @domain_alias
        lines << "\t#{@domain_alias} \"#{@domain_package}\""
      else
        lines << "\t\"#{@domain_package}\""
      end
      lines << ")"
      lines << ""
      lines << "type #{agg}MemoryRepository struct {"
      lines << "\tmu    sync.RWMutex"
      lines << "\tstore map[string]*domain.#{agg}"
      lines << "}"
      lines << ""
      lines << "func New#{agg}MemoryRepository() *#{agg}MemoryRepository {"
      lines << "\treturn &#{agg}MemoryRepository{store: make(map[string]*domain.#{agg})}"
      lines << "}"
      lines << ""
      lines << "func (r *#{agg}MemoryRepository) Find(id string) (*domain.#{agg}, error) {"
      lines << "\tr.mu.RLock()"
      lines << "\tdefer r.mu.RUnlock()"
      lines << "\t#{var}, ok := r.store[id]"
      lines << "\tif !ok { return nil, nil }"
      lines << "\treturn #{var}, nil"
      lines << "}"
      lines << ""
      lines << "func (r *#{agg}MemoryRepository) Save(#{var} *domain.#{agg}) error {"
      lines << "\tr.mu.Lock()"
      lines << "\tdefer r.mu.Unlock()"
      lines << "\tr.store[#{var}.ID] = #{var}"
      lines << "\treturn nil"
      lines << "}"
      lines << ""
      lines << "func (r *#{agg}MemoryRepository) All() ([]*domain.#{agg}, error) {"
      lines << "\tr.mu.RLock()"
      lines << "\tdefer r.mu.RUnlock()"
      lines << "\tresult := make([]*domain.#{agg}, 0, len(r.store))"
      lines << "\tfor _, v := range r.store { result = append(result, v) }"
      lines << "\treturn result, nil"
      lines << "}"
      lines << ""
      lines << "func (r *#{agg}MemoryRepository) Delete(id string) error {"
      lines << "\tr.mu.Lock()"
      lines << "\tdefer r.mu.Unlock()"
      lines << "\tdelete(r.store, id)"
      lines << "\treturn nil"
      lines << "}"
      lines << ""
      lines << "func (r *#{agg}MemoryRepository) Count() (int, error) {"
      lines << "\tr.mu.RLock()"
      lines << "\tdefer r.mu.RUnlock()"
      lines << "\treturn len(r.store), nil"
      lines << "}"

      lines.join("\n") + "\n"
    end
  end
end
