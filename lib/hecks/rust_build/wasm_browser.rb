# frozen_string_literal: true

require "fileutils"
require_relative "../rust_build"
require_relative "project_rust"
require_relative "wasm"

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
        domain = argv.first or raise Failure, "usage: hecks build_browser_wasm <domain>"
        rust_dir = RustBuild.rust_dir
        web_dir = File.join(rust_dir, "web")
        require_target!
        require_cli!(web_dir)
        scratch = scratch_copy(rust_dir)
        Wasm.regenerate(scratch, domain)
        compile(File.join(scratch, "web"), web_dir)
        bind(web_dir, File.basename(domain))
        0
      end

      # Generated in a scratch copy, as `Wasm` does, because generating rewrites `Cargo.toml` and
      # `src/generated/`, which would dirty tracked files in a checkout. The web crate's path
      # dependency `..` resolves to the scratch workspace.
      def scratch_copy(rust_dir)
        scratch = Wasm.scratch_copy(rust_dir, "project_wasm_browser")
        FileUtils.mkdir_p(File.join(scratch, "web"))
        %w[Cargo.toml Cargo.lock src].each do |entry|
          from = File.join(rust_dir, "web", entry)
          FileUtils.cp_r(from, File.join(scratch, "web")) if File.exist?(from)
        end
        scratch
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

      def compile(scratch_web, web_dir)
        puts "== cargo build --release --target #{TARGET} (rust/web) =="
        target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(web_dir, "target"))
        RustBuild.command!("rustup", "run", "stable", "cargo", "build", "--release", "--target", TARGET,
                           chdir: scratch_web, env: { "CARGO_TARGET_DIR" => target_dir })
      end

      def bind(web_dir, name)
        out_dir = File.join(RustBuild.rust_dir, "dist", "browser", name)
        FileUtils.mkdir_p(out_dir)
        built = File.join(ENV.fetch("CARGO_TARGET_DIR", File.join(web_dir, "target")), TARGET, "release",
                          "rust_web.wasm")
        puts "== wasm-bindgen --target web =="
        RustBuild.command!("wasm-bindgen", "--target", "web", "--out-dir", out_dir, "--out-name", name, built)
        puts "wrote #{out_dir}/"
        puts browser_usage(name)
      end

      def browser_usage(name)
        <<~MSG
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
