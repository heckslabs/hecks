require "json"
require_relative "errors"

module Hecks
  module Runtime
    # Runs a plugin adapter's wasm module: one question in, one answer out.
    #
    # A plugin is a WASI command, the same contract the Rust host runs its kernel by. It reads
    # `{"question": "Chapter::Aggregate.Query", "args": {...}}` as JSON on stdin and writes
    # `{"rows": [...]}` or `{"refused": "why"}` as JSON on stdout. It is given no files, network,
    # environment or arguments, so it answers from its question alone; here its clock and
    # randomness are fixed too. Both hosts run the same module, so there is one implementation to
    # trust.
    module WasmPlugin
      # How much a plugin may write before it is cut off; the Rust host uses the same cap.
      STDOUT_CAP = 64 * 1024 * 1024

      @compiled = {}
      @lock = Mutex.new

      module_function

      # Asks a plugin one question.
      #
      # @param adapter [Bluebook::Adapter] the plugin adapter whose module answers
      # @param question [String] the qualified query, such as `"Calendar::Event.Occurrences"`
      # @param args [Hash] the query's arguments as plain data, a referenced record as its state
      # @return [Array<Hash>, Hash] the plugin's rows
      # @raise [PluginRefusal] if the plugin refuses the question
      # @raise [WiringError] if the module cannot run or answers something that is not the contract
      def ask(adapter, question, args)
        reply = run(adapter, JSON.generate(question: question, args: args))
        return reply.fetch("rows") if reply.key?("rows")
        raise PluginRefusal, "#{question}: #{reply["refused"]}" if reply.key?("refused")

        raise WiringError, "#{adapter.name} answered #{question} with neither rows nor a refusal"
      end

      # Compiles a plugin's module once, so a missing or broken module stops the boot.
      #
      # @param adapter [Bluebook::Adapter] the plugin adapter to compile
      # @return [void]
      # @raise [WiringError] if the module is missing or is not wasm
      def compile!(adapter) = compiled(adapter)

      def run(adapter, input)
        engine, wasm_module, linker = compiled(adapter)
        output = +""
        config = Wasmtime::WasiConfig.new.add_determinism.set_stdin_string(input).set_stdout_buffer(output, STDOUT_CAP)
        store  = Wasmtime::Store.new(engine, wasi_p1_config: config)
        start(linker.instantiate(store, wasm_module), adapter)
        JSON.parse(output)
      rescue JSON::ParserError => e
        raise WiringError, "#{adapter.name} answered with text that is not JSON: #{e.message}"
      end

      # A command ends by returning from `_start` or by exiting; only exit code 0 is an answer.
      def start(instance, adapter)
        instance.invoke("_start")
      rescue Wasmtime::WasiExit => e
        raise WiringError, "#{adapter.name} exited with code #{e.code}" unless e.code.zero?
      rescue Wasmtime::Trap, Wasmtime::Error => e
        raise WiringError, "#{adapter.name} failed: #{e.message}"
      end

      def compiled(adapter)
        path = adapter.plugin_path
        @lock.synchronize { @compiled[path] ||= compile(adapter, path) }
      end

      def compile(adapter, path)
        require_wasmtime!(adapter)
        raise WiringError, "#{adapter.name} runs #{adapter.runs}, but there is no #{path}" unless File.file?(path)

        engine = Wasmtime::Engine.new
        linker = Wasmtime::Linker.new(engine)
        Wasmtime::WASI::P1.add_to_linker_sync(linker)
        [engine, Wasmtime::Module.from_file(engine, path), linker]
      rescue Wasmtime::Error => e
        raise WiringError, "#{adapter.name} runs #{adapter.runs}, which is not a wasm module: #{e.message}"
      end

      # Lazy, so a domain that answers no query with a plugin does not need the wasmtime gem.
      def require_wasmtime!(adapter)
        require "wasmtime"
      rescue LoadError
        raise WiringError, "#{adapter.name} is a wasm plugin, which needs the wasmtime gem: " \
                           "add `gem \"wasmtime\"` to the Gemfile"
      end
    end
  end
end
