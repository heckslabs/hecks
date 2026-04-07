# Hecks::CLI -- tree command
#
# Prints all registered CLI commands organized by group, showing
# a tree-style overview of the full command surface.
#
#   hecks tree
#   hecks tree --format json
#
Hecks::CLI.register_command(:tree, "Print all commands as a grouped tree",
  options: {
    format: { type: :string, desc: "Output format: text (default) or json" }
  }
) do
  groups = self.class.command_groups

  if options[:format] == "json"
    require "json"
    tree = groups.transform_values do |commands|
      commands.sort_by { |cmd_entry| cmd_entry[:name] }.map do |cmd|
        entry = { name: cmd[:name].to_s, description: cmd[:description] }
        entry[:args] = cmd[:args] unless cmd[:args].empty?
        entry[:options] = cmd[:options].keys.map(&:to_s) unless cmd[:options].empty?
        entry
      end
    end
    say JSON.pretty_generate(tree)
    next
  end

  say "Hecks CLI Commands", :bold
  say ""
  groups.each do |group_name, commands|
    say "#{group_name}/", :green
    sorted = commands.sort_by { |cmd_entry| cmd_entry[:name] }
    sorted.each_with_index do |cmd, cmd_index|
      connector = cmd_index == sorted.length - 1 ? "\\-- " : "|-- "
      name = cmd[:args].empty? ? cmd[:name].to_s : "#{cmd[:name]} #{cmd[:args].join(' ')}"
      opts = cmd[:options].keys
      opt_str = opts.any? ? "  [#{opts.map { |opt| "--#{opt}" }.join(', ')}]" : ""
      say "  #{connector}#{name}#{opt_str}  # #{cmd[:description]}"
    end
    say ""
  end
end
