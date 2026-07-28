module Hecksagain
  module Runtime
    class Loader
      def self.boot(path, shared: nil)
        loading   = Ports::Loading.bootstrap
        directory = loading.bluebook_directory(path)
        root      = loading.shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          loading.load_library      
          loading.load_project(root) 
          loading.load_domain(directory)
        end

        registry.verify!
        bind_runtime(Dispatcher.new(registry))
      end

      def self.bind_runtime(dispatcher)
        dispatcher.registry.bluebooks.each_value do |bluebook|
          bluebook.aggregates.each { |aggregate| aggregate.ruby_class.runtime = dispatcher }
        end
        dispatcher
      end
    end
  end
end
