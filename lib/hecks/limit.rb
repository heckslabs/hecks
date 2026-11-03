require_relative "vocabulary"

module Hecks
  # A number the language declares, read by name from a two-column vocabulary table
  # (`LanguageLimit`, `ModelCheckLimit`), so the code that enforces it holds no copy of it.
  module Limit
    module_function

    # @param table [String] a vocabulary table of `name` and `value` rows
    # @param name [String] the row's name
    # @return [Integer] the row's value
    # @raise [KeyError] if the table has no such row: a limit the language does not declare is a
    #   typo
    def of(table, name)
      row = Hecks::Vocabulary.rows(table).find { |candidate| candidate["name"] == name }
      Integer(row.fetch("value"))
    rescue NoMethodError
      raise KeyError, "#{table} declares no limit named #{name.inspect}"
    end
  end
end
