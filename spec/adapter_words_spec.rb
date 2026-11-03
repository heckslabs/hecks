require "spec_helper"
require "json"

# ADR 0163 step 66: a domain name (a module, an aggregate, a command or a query) must not equal a
# technology word the adapters are named for. The list is declared as data beside the hecksagon,
# so a later adapter swap cannot rename a domain's own vocabulary.
module AdapterWords
  ROOT = File.expand_path("..", __dir__)
  WORDS_FILE = File.join(ROOT, "lib/hecks/hecks/adapter_words.json")
  BLUEBOOKS = Dir.glob(File.join(ROOT, "lib/hecks/**/*.bluebook"))
  DECLARED = /^\s*(?:aggregate|domain_module|command|query)\s+"([A-Za-z]+)"/

  module_function

  def words(file = WORDS_FILE)
    JSON.parse(File.read(file)).fetch("words").map(&:downcase)
  end

  def domain_names(files = BLUEBOOKS)
    files.flat_map { |file| File.read(file).scan(DECLARED).flatten.map { |name| [name, file] } }
  end

  # The domain names that equal a technology word, as [name, file, word] triples.
  def collisions(word_list = words, names = domain_names)
    names.filter_map { |name, file| [name, file, name.downcase] if word_list.include?(name.downcase) }
  end
end

RSpec.describe "domain names avoid technology words" do
  it "names no domain name equal to a technology word" do
    expect(AdapterWords.collisions).to be_empty
  end

  it "names a fixture collision" do
    expect(AdapterWords.collisions(["sqlite"], [["Sqlite", "fixture.bluebook"]])).not_to be_empty
  end

  it "passes a fixture that is not a technology word" do
    expect(AdapterWords.collisions(["sqlite"], [["Mail", "fixture.bluebook"]])).to be_empty
  end
end
