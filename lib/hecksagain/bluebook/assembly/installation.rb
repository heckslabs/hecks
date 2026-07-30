module Hecksagain
  module Bluebook
    class Assembly
      # The chapter's namespace, and the constants that reach it.
      #
      # Lifted out of `BluebookBuilder#build` unchanged in behaviour: the chapter
      # module is the top of the construct chain, every head hangs off it, and the
      # heads are installed at top level so `Pizza.create_pizza(…)` works.
      #
      # `Namespace.install` is the one that refuses to clobber user code — which is
      # why a chapter named `Set` never becomes a constant, and why `Registry` keeps
      # a table of chapters rather than trusting Ruby's.
      class Installation
        def initialize(chapter, read_models)
          @chapter     = chapter
          @read_models = read_models
        end

        def install
          namespace = Module.new
          namespace.extend(Construct)
          namespace.hecks_name = @chapter.hecks_name
          namespace.hecks_root = true

          # A read model gathers heads from SEVERAL aggregates, so no one head
          # declares it — the chapter does.
          @read_models.each { |model| model.hecks_owner = namespace }

          @chapter.aggregates.each do |aggregate|
            aggregate.ruby_class.domain = @chapter.hecks_name
            aggregate.ruby_class.hecks_owner = namespace
            namespace.const_set(aggregate.hecks_name, aggregate.ruby_class)
          end

          chapter = @chapter
          namespace.define_singleton_method(:vision)     { chapter.vision }
          namespace.define_singleton_method(:aggregates) { chapter.aggregates.map(&:name).sort }

          Namespace.install(Object, @chapter.hecks_name, namespace)
          @chapter.aggregates.each do |aggregate|
            next if aggregate.hecks_name == @chapter.hecks_name

            Namespace.install(Object, aggregate.hecks_name, aggregate.ruby_class)
          end

          namespace
        end
      end
    end
  end
end
