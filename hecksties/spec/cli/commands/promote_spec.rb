require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks promote" do
  before { allow($stdout).to receive(:puts) }

  it "extracts an aggregate into a standalone domain file" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PizzasBluebook"), <<~RUBY)
        Hecks.domain "Blog" do
          aggregate "Post" do
            attribute :title, String
            command "CreatePost" do
              attribute :title, String
            end
          end
          aggregate "Comment" do
            attribute :body, String
            command "CreateComment" do
              attribute :body, String
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        cli = Hecks::CLI.new
        allow(cli).to receive(:say)
        cli.promote("Comment")

        # New domain file created
        expect(File.exist?(File.join(dir, "comment_domain.rb"))).to be true
        new_content = File.read(File.join(dir, "comment_domain.rb"))
        expect(new_content).to include('Hecks.domain "Comment"')
        expect(new_content).to include("body")

        # Original domain updated without Comment
        original = File.read(File.join(dir, "PizzasBluebook"))
        expect(original).to include("Post")
        expect(original).not_to include("Comment")
      end
    end
  end
end
