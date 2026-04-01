Hecks::CLI.register_command(:build, "Generate the domain gem",
  options: {
    domain:  { type: :string,  desc: "Domain gem name or path" },
    version: { type: :string,  desc: "Domain version" },
    target:  { type: :string,  desc: "Build target: ruby (default), static, go, node, rails" },
    static:  { type: :boolean, desc: "Generate static gem (alias for --target static)" }
  }
) do

  domain = resolve_domain_option
  unless domain
    say "Error: must be run from a directory containing Bluebook", :red
    raise SystemExit.new(1)
  end
  validator = Hecks::Validator.new(domain)
  unless validator.valid?
    say "Domain validation failed:", :red
    validator.errors.each do |e|
      say "  - #{e}", :red
      say "    Fix: #{e.hint}", :cyan if e.respond_to?(:hint) && e.hint
    end
    next
  end

  target = options[:target] || (options[:static] ? "static" : "ruby")
  versioner = Hecks::Versioner.new(".")

  latest_ver = Hecks::DomainVersioning.latest_version(base_dir: ".")
  old_domain = latest_ver ? Hecks::DomainVersioning.load_version(latest_ver, base_dir: ".") : nil
  bump_result = Hecks::DomainVersioning::BreakingBumper.call(old_domain, domain, versioner)
  version = bump_result[:version]

  if bump_result[:bumped]
    say "Breaking changes detected — auto-bumped to v#{version}:", :yellow
    bump_result[:breaking_changes].each { |c| say "  #{c[:label]}", :red }
  end

  builder = Hecks.target_registry[target.to_sym]
  unless builder
    say "Unknown build target: #{target}. Available: #{Hecks.target_registry.keys.join(', ')}", :red
    next
  end

  opts = case target
         when "go"    then { smoke_test: false }
         when "node"  then {}
         when "rails" then { output_dir: "." }
         else              { version: version }
         end

  output = builder.call(domain, **opts)

  case target
  when "go"
    say "Built #{domain.name} Go project", :green
    say "  Output: #{output}/"
    if system("which go > /dev/null 2>&1")
      say "  Compiling Go binary..."
      slug = domain_slug(domain.name)
      binary = "#{slug}_server"
      if system("cd #{output} && go mod tidy 2>&1 && go build -o #{binary} ./cmd/#{slug}/ 2>&1")
        say "  Binary: #{output}/#{binary}", :green
      else
        say "  Go compilation failed — run `go build` manually", :yellow
      end
    else
      say "  Go not installed — run `go build` in #{output}/ to compile", :yellow
    end
  when "node"
    say "Built #{domain.name} Node.js/TypeScript project", :green
    say "  Output: #{output}/"
    say "  cd #{output} && npm install && npm run dev"
  when "static"
    say "Built #{domain.gem_name} v#{version} (static)", :green
    say "  Output: #{output}/"
  when "rails"
    say "Built Rails app: #{output}/", :green
    say "  cd #{output} && bundle install && rails server"
  else
    say "Built #{domain.gem_name} v#{version}", :green
    say "  Docs: #{output}/docs/"
    say "  Output: #{output}/"
  end
end
