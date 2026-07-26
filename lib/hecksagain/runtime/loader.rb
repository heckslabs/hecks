# Loader — boot, and the one bootstrap the hexagon cannot close over itself.
#
# Everything boot does to a disk — globbing a directory, testing a path, walking
# up for a project's own ports, evaluating each file — now belongs to the LOADING
# port and its Folder adapter. What is left here is the sequence: find the
# domain, open a registry, ask the loading adapter for the declarations in
# dependency order, verify the wiring, hand back a dispatcher.
#
# THE BOOTSTRAP. The loading port cannot be resolved the way persistence or
# extraction are, because resolving a port means reading the file that declares
# it — and reading files is the thing this port DOES. So `bootstrap` names the
# one adapter boot must know before it can know anything, and constructs it
# directly. That circularity is real and cannot be argued away. What it can be
# is small, named, and confined to a single method, rather than spread through
# boot as unexamined Dir[] calls — which is exactly what it was.
#
# Once the library's declarations are in the registry, every other edge resolves
# through its port like any other.
#
#   Loader.boot("examples/pizzas")  # => Dispatcher
module Hecksagain
  module Runtime
    class Loader
      def self.boot(path, shared: nil)
        loading   = Ports::Loading.bootstrap
        directory = loading.bluebook_directory(path)
        root      = loading.shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          loading.load_library      # the library's own — always
          loading.load_project(root) # a project's own, if it has any
          loading.load_domain(directory)
        end

        registry.verify!
        bind_runtime(Dispatcher.new(registry))
      end

      # The classes were constructed while the bluebook was read, before any
      # runtime existed. Boot is where they learn which one they belong to.
      def self.bind_runtime(dispatcher)
        dispatcher.registry.bluebooks.each_value do |bluebook|
          bluebook.aggregates.each { |aggregate| aggregate.ruby_class.runtime = dispatcher }
        end
        dispatcher
      end
    end
  end
end
