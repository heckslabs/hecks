# frozen_string_literal: true

require_relative "../rust_build"
require_relative "kernel_client"
require_relative "kernel_hello"
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
      # @param environment [String, nil, Symbol] the overlay `Hecks.describe` reads, or `FROM_ENV`
      # @return [Runtime::KernelDispatcher] connected to a kernel for the domain
      # @raise [NotMemory] when an aggregate persists anywhere but Memory
      # @raise [BinaryUnavailable] when the feature is not declared or its build fails
      def boot(path, binary: nil, environment: Assembly::FROM_ENV)
        described = Hecks.describe(path, environment: environment)
        require_memory!(described.registry)
        connect(described.registry, feature_of(described.directory), binary: binary)
      end

      # Reads exactly the named files' declarations, as `Hecks.boot_files` loads them, and binds no
      # adapter. The caller checks the declarations before {connect} builds a kernel for them; this
      # makes no Memory check of its own, so a behaviors suite keeps its own refusal.
      #
      # @param files [Array<String>] the bluebook, hecksagon and world files, absolute, in order
      # @param adapters [Array<String>, nil] exactly the `.adapter` files to load; nil leaves the
      #   loader's own choice
      # @return [Runtime::Registry] the declarations
      def describe_files(files, adapters: nil)
        Runtime::Loader.load_files(Ports::Loading.bootstrap, files + Array(adapters), nil,
                                   Assembly.selected_environment(Assembly::FROM_ENV), chosen: !adapters.nil?)
      end

      # Connects a kernel dispatcher for already-read declarations; it checks no persistence. The
      # hello carries the tables the declarations' IR builds; a clock fact a step leaves out is
      # filled, and a fact the kernel asks for answered, from the registry's clock port (see
      # {KernelHello}).
      #
      # @param registry [Runtime::Registry] the declarations the kernel runs
      # @param feature [String] the Cargo feature the kernel is built with
      # @param binary [String, nil] a kernel binary to use instead of building the feature
      # @return [Runtime::KernelDispatcher] connected, answering `registry` from the declarations
      # @raise [BinaryUnavailable] when the feature is not declared or its build fails
      def connect(registry, feature, binary: nil)
        tables = KernelHello.tables(registry)
        hello = { tables: tables, fill: KernelHello.filler(registry, tables) }
        client = KernelClient.open(binary || binary_for(feature), **hello, &KernelHello.answerer(registry))
        Runtime::KernelDispatcher.new(client, registry: registry)
      end

      # @param feature [String] a Cargo feature name
      # @return [Boolean] whether `rust/Cargo.toml` declares it, so a kernel can be built for it
      def feature?(feature)
        File.read(File.join(RustBuild.rust_dir, "Cargo.toml")).match?(/^#{Regexp.escape(feature)}\s*=\s*\[\]/)
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
