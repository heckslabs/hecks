# Hecks::CLI -- architecture command
#
# Displays a hexagonal architecture diagram for the current domain,
# showing driving ports (actors/inbound) and driven ports (outbound adapters).
#
#   hecks architecture
#
Hecks::CLI.register_command(:architecture, "Show hexagonal architecture diagram") do
  require "hecks"

  begin
    Hecks.boot(Dir.pwd)
  rescue StandardError
    # Fall back to showing the hecksagon if no bootable domain
  end

  hecksagon = Hecks.last_hecksagon
  unless hecksagon
    say "No hecksagon found. Run from a directory with hecks/*.bluebook files.", :red
    next
  end

  driving = hecksagon.respond_to?(:driving_ports) ? Array(hecksagon.driving_ports) : []
  driven  = hecksagon.respond_to?(:driven_ports)  ? Array(hecksagon.driven_ports)  : []
  domains = hecksagon.respond_to?(:domains) ? Array(hecksagon.domains) : []

  hex_label = hecksagon.respond_to?(:name) ? hecksagon.name : "Hecksagon"
  box_width = [hex_label.length + 4, 24].max

  say ""
  say "Hexagonal Architecture: #{hex_label}", :bold
  say ""

  if driving.any?
    say "  Driving (inbound):", :green
    driving.each do |port|
      label = port.respond_to?(:name) ? port[:name] : port.to_s
      say "    #{label} ──> |"
    end
    say ""
  end

  border = "+" + "-" * box_width + "+"
  say "  #{border}"
  say "  |#{hex_label.center(box_width)}|"

  if domains.any?
    domains.each do |d|
      name = d.respond_to?(:name) ? d.name : d.to_s
      say "  |#{name.center(box_width)}|"
    end
  end

  say "  #{border}"

  if driven.any?
    say ""
    say "  Driven (outbound):", :yellow
    driven.each do |port|
      label = port.respond_to?(:name) ? port[:name] : port.to_s
      say "    | ──> #{label}"
    end
  end

  say ""
end
