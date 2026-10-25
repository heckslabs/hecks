require "spec_helper"

# The hecks-rails boundary, held both ways: a Rails app and the hecks-rails package never name the
# runtime, and nothing under lib/hecks requires Rails or ActiveModel.
RSpec.describe "the hecks-rails boundary" do
  # Every Ruby and view file of the package, its fixture apps included.
  def package_files
    Dir.glob(File.join(InMemoryDomain::ROOT, "packages/hecks-rails/**/*.{rb,erb}"))
  end

  # Every file under lib/hecks that requires a Rails or ActiveModel library.
  def core_files_requiring_rails
    Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/**/*.rb")).select do |path|
      File.read(path).match?(/^\s*require ["'](rails|active_model|active_support|action_\w+)/)
    end
  end

  it "keeps the package and its fixture apps from naming Hecks::Runtime" do
    expect(package_files.select { |path| File.read(path).match?(/Hecks::Runtime|\bRuntime::/) }).to be_empty
  end

  it "keeps core free of Rails and ActiveModel" do
    expect(core_files_requiring_rails).to be_empty
  end
end
