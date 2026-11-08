# Reads the DiskSpace bluebook's rows from a booted Hecks domain, and judges a level from the
# `Verdict` rows against a set of lines, as the adapter that measures a volume will.
module DiskSpaceRows
  # @return [Hecks::Domain] the Hecks bluebook with DiskSpace attached
  def hecks_bluebook = @hecks_bluebook ||= InMemoryDomain.boot_hecks_in_memory.registry.bluebook("Hecks")

  # @param aggregate_name [String]
  # @param table [String] a value object holding rows
  # @return [Array<Hash>] its rows
  def rows(aggregate_name, table)
    hecks_bluebook.aggregate(aggregate_name).value_objects.find { |v| v.hecks_name == table }.members
  end

  # @return [Array<String>] the descriptions of a command's givens
  def givens(aggregate_name, command_name)
    hecks_bluebook.aggregate(aggregate_name).commands.find { |c| c.hecks_name == command_name }.givens.map(&:description)
  end

  # @return [Hash{String => Integer}] the default lines
  def lines = rows("Level", "Setting").to_h { |row| [row[:name], row[:value]] }

  # @param free_gb [Numeric]
  # @param used_percent [Numeric]
  # @param settings [Hash{String => Integer}] the lines to judge against
  # @return [String] calm, rising or high
  def level(free_gb, used_percent, settings = lines)
    reading = { free_gb: free_gb, used_percent: used_percent }
    rule = rows("Level", "Verdict").sort_by { |row| row[:position] }.find { |row| holds?(row, reading, settings) }
    rule[:level]
  end

  private

  def holds?(rule, reading, settings)
    return true if rule[:op] == "always"

    value = reading[rule[:measure].to_sym]
    rule[:op] == "<" ? value < settings[rule[:than]] : value >= settings[rule[:than]]
  end
end
