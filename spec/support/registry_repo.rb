require "fileutils"
require "open3"

# A throwaway git repository standing in for a bluebook registry: packages
# under `<name>/bluebook.yml` and `<name>/bluebook/*.bluebook`, tagged `<name>-vX.Y.Z`.
class RegistryRepo
  attr_reader :path

  # @param path [String] a directory to initialise as a repository
  def initialize(path)
    @path = path
    FileUtils.mkdir_p(path)
    git("init", "-q", "-b", "main")
  end

  # A minimal valid bluebook for the package `widgets`.
  #
  # @param description [String] the aggregate's description, which no storage shape depends on
  # @param extra_attribute [Boolean] whether the aggregate carries a second attribute, which does
  # @return [String] bluebook source text
  def self.widgets_bluebook(description: "A widget.", extra_attribute: false)
    <<~RUBY
      Hecks.bluebook "Widgets" do
        vision "Track widgets."
        supporting

        aggregate "Widget" do
          description #{description.inspect}
          identified_by :name
          attribute :name, WidgetName
          #{"attribute :colour, WidgetColour, optional: true" if extra_attribute}

          value_object "WidgetName" do
            attribute :value, String
            invariant("a widget is named") { !value.to_s.empty? }
          end
          #{colour_value_object if extra_attribute}

          command "Create" do
            goal "Make a widget"
            attribute :name, WidgetName
          end
        end
      end
    RUBY
  end

  # Builds the value object the optional second attribute uses.
  #
  # @return [String] a value object declaration
  def self.colour_value_object
    <<~RUBY.strip
      value_object "WidgetColour" do
        attribute :value, String
        invariant("a colour is named") { !value.to_s.empty? }
      end
    RUBY
  end

  # Writes files into the working tree.
  #
  # @param files [Hash{String => String}] repository-relative path to content
  # @return [void]
  def write(files)
    files.each do |file, text|
      full = File.join(path, file)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
  end

  # Commits everything in the working tree.
  #
  # @param message [String] the commit message
  # @return [String] the new commit's full id
  def commit(message = "fixture")
    git("add", "-A")
    git("-c", "user.name=Spec", "-c", "user.email=spec@example.com", "commit", "-q", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  # Tags the current commit with an annotated tag.
  #
  # @param name [String] the tag name
  # @return [void]
  def tag(name)
    git("-c", "user.name=Spec", "-c", "user.email=spec@example.com", "tag", "-a", name, "-m", name)
  end

  # Runs git inside the repository.
  #
  # @param args [Array<String>] git arguments
  # @return [String] standard output
  # @raise [RuntimeError] if the command exits non-zero
  def git(*args)
    out, err, status = Open3.capture3(Hecks::Vendoring::GitEnvironment.clean, "git", "-C", path, *args)
    raise "git #{args.first} failed: #{err}" unless status.success?

    out
  end
end
