# frozen_string_literal: true

require "json"
require_relative "cli_help_launcher"
require_relative "cli_help_mask"

# The bluebooks' side of the launcher's help: what each command, query, aggregate and bluebook
# declares about itself, and the help's rows that say something else. Each cut a section makes
# is the projector's own (`first_sentence`, `CliAudience.clipped`), never one written again here.
module CliHelpDescriptions
  module_function

  # The projector whose cuts the help shows.
  def projector = Hecks::Projector::CliProjector

  # The bluebooks the launcher lists, by name.
  #
  # @return [Hash{String => Hecks::Bluebook::Declaration}]
  def bluebooks
    @bluebooks ||= Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__)).bluebooks.to_h
  end

  # The `hecks --json` entries, by the call each spells and by its real call, which the help lists
  # for a command the bluebook gave a short name (`Operation.open_console!` for `console!`).
  #
  # @return [Hash{String => Hash}]
  def entries
    @entries ||= JSON.parse(CliHelpLauncher.output(["--json"])).each_with_object({}) do |entry, index|
      index[entry["call"]] = entry
      index[real_call(entry)] = entry
    end
  end

  # An entry's call by its real name: its aggregate, then its verb in snake case, with the `!`
  # that marks a command.
  def real_call(entry)
    aggregate, verb = entry["name"].split("::").last.split(".")
    "#{aggregate}.#{Hecks::Naming.snake(verb)}#{"!" if entry["kind"] == "command"}"
  end

  # The listed commands whose description is not the goal their bluebook declares.
  #
  # @return [Array<String>] each such command's qualified name
  def undeclared_commands
    commands = entries.values.select { |entry| entry["kind"] == "command" }
    commands.reject { |entry| declared_goal(entry) == entry["description"] }.map { |entry| entry["name"] }
  end

  # The goal the Hecks bluebook declares for a listed command, or nil when it declares none.
  def declared_goal(entry)
    aggregate_name, command = entry["name"].split("::").last.split(".")
    aggregate = bluebooks.fetch("Hecks").aggregates.find { |each| each.hecks_name == aggregate_name }
    aggregate&.commands&.find { |each| each.hecks_name == command }&.goal
  end

  # Every described row of the pinned help lines.
  def listed_rows
    CliHelpLauncher::SNAPSHOTS.values.flat_map { |argv| CliHelpMask.rows(CliHelpLauncher.output(argv)) }
  end

  # The command, query and everyday rows that do not say their entry's description as their
  # section cuts it.
  #
  # @return [Array<String>] each such row, said by section, aggregate and name
  def misquoted_rows
    rows = listed_rows.reject { |row| row[:section] == "bluebooks" }
    rows.reject { |row| (entry = entry_for(row)) && row[:text] == as_cut(row, entry["description"]) }
        .map { |row| "#{row[:section]} #{row[:group]} #{row[:name]}: #{row[:text].inspect}" }
  end

  # A row's entry: under its aggregate's heading, or by its own name for a query of the bluebook.
  def entry_for(row)
    qualified = "#{row[:group]}.#{row[:name]}"
    entries.key?(qualified) ? entries[qualified] : entries[row[:name]]
  end

  # A description as a row of its section shows it.
  def as_cut(row, description)
    return description if row[:section] == "commands"
    return projector.first_sentence(description) if row[:section] == "queries"

    Hecks::Projector::CliAudience.clipped(projector.first_sentence(description), projector::Everyday::EVERYDAY_TEXT)
  end

  # The bluebook rows that are not the start of that bluebook's vision.
  #
  # @return [Array<Hash>] each such row
  def misquoted_bluebooks
    visions = bluebooks.to_h { |name, bluebook| [Hecks::Naming.snake(name), bluebook.vision.to_s] }
    rows = listed_rows.select { |row| row[:section] == "bluebooks" }
    rows.reject { |row| visions.fetch(row[:name], "").start_with?(row[:text].chomp("…")) }
  end

  # The aggregate notes that are not the first sentence of their aggregate's description.
  #
  # @return [Array<Hash>] each such note
  def misquoted_notes
    described = aggregate_descriptions
    notes = CliHelpLauncher::SNAPSHOTS.values.flat_map { |argv| CliHelpMask.notes(CliHelpLauncher.output(argv)) }
    notes.reject { |note| projector.first_sentence(described[note[:group]]) == note[:text] }
  end

  # Each aggregate's description, by its name, across the listed bluebooks; the Hecks bluebook's
  # own aggregate wins a name another bluebook shares, as the launcher lists it.
  def aggregate_descriptions
    bluebooks.values.reverse.flat_map(&:aggregates).to_h { |each| [each.hecks_name, each.description.to_s] }
  end
end
