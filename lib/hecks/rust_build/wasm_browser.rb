# frozen_string_literal: true

require "fileutils"
require_relative "../rust_build"
require_relative "project_rust"

module Hecks
  module RustBuild
    # Builds the `rust/web` wasm-bindgen crate over a domain's generated code
    # (docs/decisions/0015-wasm-bindgen-browser-projection.md).
    #
    #   WasmBrowser.call(["path/to/domain"])
    #
    # Writes `<workspace>/dist/browser/<domain>/{<domain>.js,<domain>_bg.wasm,*.d.ts}`, an ES
    # module whose `dispatch(json)` returns the same `{"instances","events","refusals"}` JSON as
    # the WASI module.
    module WasmBrowser
      # The Cargo target the module is built for.
      TARGET = "wasm32-unknown-unknown"

      module_function

      # @param argv [Array<String>] the domain's directory
      # @return [Integer] the exit status
      # @raise [Failure] when the target or the matching wasm-bindgen CLI is missing, or a step
      #   fails
      def call(argv)
        domain = argv.first or raise Failure, "usage: bin/project_wasm_browser <domain>"
        web_dir = File.join(RustBuild.rust_dir, "web")
        name = File.basename(domain)
        require_target!
        require_cli!(web_dir)
        puts "== regenerating rust/src/generated/ for #{domain} =="
        raise Failure, "project_rust failed for #{domain}" unless ProjectRust.call([domain]).zero?

        compile(web_dir)
        bind(web_dir, name)
        0
      end

      def require_target!
        return if system("rustup target list --installed 2>/dev/null | grep -qx #{TARGET}")

        raise Failure, <<~MSG
          #{TARGET} isn't installed for this toolchain. Install it once with:

              rustup target add #{TARGET}

          then re-run the build.
        MSG
      end

      # The wasm-bindgen CLI must match the crate version pinned in `rust/web/Cargo.toml`; a
      # mismatch fails only when the CLI runs, so the pin is read back, not hardcoded.
      def require_cli!(web_dir)
        pinned = File.read(File.join(web_dir, "Cargo.toml"))[/^wasm-bindgen = "=(.+)"/, 1] or
          raise Failure, "rust/web/Cargo.toml: couldn't find a pinned (\"=x.y.z\") wasm-bindgen version"
        installed = `wasm-bindgen --version 2>/dev/null`[/[\d.]+/]
        return if installed == pinned

        raise Failure, <<~MSG
          wasm-bindgen CLI #{installed.inspect} != the pinned crate version #{pinned.inspect}. Install the matching CLI once with:

              cargo install wasm-bindgen-cli --version #{pinned} --locked

          then re-run the build.
        MSG
      end

      def compile(web_dir)
        puts "== cargo build --release --target #{TARGET} (rust/web) =="
        RustBuild.command!("rustup", "run", "stable", "cargo", "build", "--release", "--target", TARGET,
                           chdir: web_dir)
      end

      def bind(web_dir, name)
        out_dir = File.join(RustBuild.rust_dir, "dist", "browser", name)
        FileUtils.mkdir_p(out_dir)
        built = File.join(ENV.fetch("CARGO_TARGET_DIR", File.join(web_dir, "target")), TARGET, "release",
                          "rust_web.wasm")
        puts "== wasm-bindgen --target web =="
        RustBuild.command!("wasm-bindgen", "--target", "web", "--out-dir", out_dir, "--out-name", name, built)
        puts "wrote #{out_dir}/"
        puts <<~MSG
          use it in a browser:
              <script type="module">
                import init, { dispatch } from "./#{name}.js";
                await init();
                const result = dispatch(JSON.stringify({ steps: [...] }));
              </script>
        MSG
      end
    end
  end
end
