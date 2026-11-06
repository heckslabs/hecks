# frozen_string_literal: true

require_relative "../rust_build"
require_relative "kernel_client"
require_relative "native_build"
require_relative "../runtime/kernel_dispatcher"

module Hecks
  module RustBuild
    # Boots a domain on the Rust kernel instead of the Ruby interpreter (ADR 0188 step 5), for
    # `Hecks.boot(path, engine: :kernel)`. The kernel binary is built for the domain's Cargo
    # feature the way `NativeBuild.build_rust_for` builds it, and a {Runtime::KernelDispatcher}
    # speaks to it.
    #
    # It never falls back to Ruby: a binary that cannot be had, and a domain whose persistence
    # is not Memory, are refused by name.
    module KernelEngine
      # Raised when no kernel binary can be had for the domain.
      class BinaryUnavailable < StandardError; end

      # Raised when a domain's persistence is not Memory, the only store the kernel holds.
      class NotMemory < StandardError; end

      MEMORY = "Memory"

      module_function

      # @param path [String] a domain directory, or the `bluebook` directory inside one
      # @param binary [String, nil] a kernel binary to use instead of building the domain's feature
      # @return [Runtime::KernelDispatcher] connected to a kernel for the domain
      # @raise [NotMemory] when an aggregate persists anywhere but Memory
      # @raise [BinaryUnavailable] when the feature is not declared or its build fails
      def boot(path, binary: nil)
        described = Hecks.describe(path)
        require_memory!(described.registry)
        binary ||= binary_for(feature_of(described.directory))
        Runtime::KernelDispatcher.new(KernelClient.open(binary))
      end

      # @param directory [String] the described bluebook directory
      # @return [String] the domain directory's name, which is also its Cargo feature
      def feature_of(directory)
        dir = File.expand_path(directory)
        File.basename(dir) == "bluebook" ? File.basename(File.dirname(dir)) : File.basename(dir)
      end

      # @param feature [String] the Cargo feature
      # @return [String] the built kernel binary
      # @raise [BinaryUnavailable] when the feature is undeclared or the build fails
      def binary_for(feature)
        NativeBuild.build_rust_for(feature, RustBuild.rust_dir) ||
          raise(BinaryUnavailable, "no kernel binary: rust/Cargo.toml declares no feature #{feature.inspect}")
      rescue NativeBuild::BuildFailed => e
        raise BinaryUnavailable, "no kernel binary for #{feature.inspect}: #{e.message}"
      end

      # @param registry [Runtime::Registry] the described declarations
      # @return [void]
      # @raise [NotMemory] naming each aggregate bound to another adapter
      def require_memory!(registry)
        elsewhere = bound_elsewhere(registry)
        return if elsewhere.empty?

        raise NotMemory, "the kernel engine holds Memory only; #{elsewhere.join(", ")} persist elsewhere"
      end

      def bound_elsewhere(registry)
        registry.bluebooks.flat_map do |domain, bluebook|
          bluebook.aggregates.filter_map do |aggregate|
            bind = Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate)
            "#{domain}::#{aggregate.name} (#{bind.adapter})" unless bind.adapter.to_s == MEMORY
          end
        end
      end
    end
  end
end
