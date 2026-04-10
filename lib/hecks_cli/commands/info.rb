Hecks::CLI.handle(:info) do |inv|
  load_all_domains_local = lambda do
    domains_dir = File.join(Dir.pwd, "domains")
    if File.directory?(domains_dir)
      Dir[File.join(domains_dir, "*.rb")].sort.map do |path|
        eval(File.read(path), nil, path, 1)
      end
    elsif File.exist?(Dir[File.join(Dir.pwd, "*Bluebook")].first)
      [load_domain_file(Dir[File.join(Dir.pwd, "*Bluebook")].first)]
    else
      say "No domains/ directory or Bluebook found", :red
      []
    end
  end

  find_event_source = lambda do |domains, event_name|
    domains.each do |d|
      d.aggregates.each do |a|
        return d.name if a.events.any? { |e| e.name == event_name }
      end
    end
    "?"
  end

  find_command_target = lambda do |domains, command_name|
    domains.each do |d|
      d.aggregates.each do |a|
        return d.name if a.commands.any? { |c| c.name == command_name }
      end
    end
    "?"
  end

  say_domains = lambda do |domains|
    say "Domains (#{domains.size}):", :green
    domains.each do |d|
      aggs = d.aggregates.map(&:name).join(", ")
      say "  #{d.name.ljust(20)} — #{aggs}"
    end
    say ""
  end

  say_extensions = lambda do
    available = []
    require "hecks/runtime/load_extensions"
    Hecks::LoadExtensions::AUTO.each do |name|
      Hecks::LoadExtensions.require_if_available(name)
      available << name.to_s if Hecks.extension_registry.key?(name)
    end
    if available.any?
      say "Extensions:", :green
      available.each { |e| say "  #{e}" }
      say ""
    end
  end

  say_services = lambda do
    svc_dir = File.join(Dir.pwd, "services")
    return unless File.directory?(svc_dir)
    files = Dir[File.join(svc_dir, "*.rb")].sort
    return if files.empty?
    say "Services (#{files.size}):", :green
    files.each do |f|
      name = Hecks::Utils.sanitize_constant(File.basename(f, ".rb"))
      say "  #{name}"
    end
    say ""
  end

  say_cross_domain_policies = lambda do |domains|
    policies = []
    domains.each do |d|
      d.aggregates.each do |agg|
        agg.policies.select(&:reactive?).each do |p|
          source = find_event_source.call(domains, p.event_name)
          target = find_command_target.call(domains, p.trigger_command)
          policies << { name: p.name, event: p.event_name,
                        trigger: p.trigger_command,
                        from: source, to: target,
                        conditional: !!p.condition }
        end
      end
      d.policies.select(&:reactive?).each do |p|
        source = find_event_source.call(domains, p.event_name)
        target = find_command_target.call(domains, p.trigger_command)
        policies << { name: p.name, event: p.event_name,
                      trigger: p.trigger_command,
                      from: source, to: target,
                      conditional: !!p.condition }
      end
    end
    if policies.any?
      say "Cross-domain events:", :green
      policies.each do |p|
        cond = p[:conditional] ? " (conditional)" : ""
        say "  #{p[:event].ljust(25)} → #{p[:trigger].ljust(20)} (#{p[:from]} → #{p[:to]})#{cond}"
      end
    end
  end

  say_boundary_advisories = lambda do |domains|
    all_warnings = []
    domains.each do |d|
      validator = Hecks::Validator.new(d)
      validator.valid?
      validator.warnings.each { |w| all_warnings << "#{d.name}: #{w}" }
    end
    if defined?(Hecks::MultiDomain::Validator)
      Hecks::MultiDomain::Validator.ambiguous_name_warnings(domains).each do |w|
        all_warnings << w
      end
    end
    if all_warnings.any?
      say ""
      say "Boundary advisories:", :yellow
      all_warnings.each { |w| say "  - #{w}", :yellow }
    end
  end

  domains = load_all_domains_local.call
  next if domains.empty?

  say_domains.call(domains)
  say_extensions.call
  say_services.call
  say_cross_domain_policies.call(domains)
  say_boundary_advisories.call(domains)
end
