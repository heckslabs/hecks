require "spec_helper"
require "tmpdir"

RSpec.describe "Import.from_directory" do
  let(:project_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(project_dir) }

  def write_model(name, content)
    models_dir = File.join(project_dir, "app", "models")
    FileUtils.mkdir_p(models_dir)
    File.write(File.join(models_dir, "#{name}.rb"), content)
  end

  def write_schema(content)
    schema_dir = File.join(project_dir, "db")
    FileUtils.mkdir_p(schema_dir)
    File.write(File.join(schema_dir, "schema.rb"), content)
  end

  context "with schema.rb present (Rails project)" do
    before do
      write_schema(<<~RUBY)
        ActiveRecord::Schema.define(version: 2024_01_01) do
          create_table "posts" do |t|
            t.string "title"
            t.text "body"
            t.timestamps
          end
        end
      RUBY
      write_model("post", <<~RUBY)
        class Post < ApplicationRecord
          validates :title, presence: true
        end
      RUBY
    end

    it "uses full Rails import with schema" do
      dsl = Hecks::Import.from_directory(project_dir, domain_name: "Blog")
      expect(dsl).to include('Hecks.domain "Blog"')
      expect(dsl).to include("attribute :title, String")
      expect(dsl).to include("attribute :body, String")
      expect(dsl).to include("validation :title")
    end
  end

  context "without schema.rb (models only)" do
    before do
      write_model("pizza", <<~RUBY)
        class Pizza < ApplicationRecord
          belongs_to :restaurant
          has_many :toppings
          enum status: { draft: 0, published: 1 }
        end
      RUBY
    end

    it "falls back to model-only extraction" do
      dsl = Hecks::Import.from_directory(project_dir, domain_name: "Pizzeria")
      expect(dsl).to include('Hecks.domain "Pizzeria"')
      expect(dsl).to include('reference_to "Restaurant"')
      expect(dsl).to include('list_of "Topping"')
      expect(dsl).to include("attribute :status, String, enum:")
    end
  end

  context "with models in a models/ subdirectory" do
    before do
      models_dir = File.join(project_dir, "models")
      FileUtils.mkdir_p(models_dir)
      File.write(File.join(models_dir, "widget.rb"), <<~RUBY)
        class Widget < ApplicationRecord
          validates :name, presence: true
        end
      RUBY
    end

    it "detects models/ directory" do
      dsl = Hecks::Import.from_directory(project_dir, domain_name: "Widgets")
      expect(dsl).to include('aggregate "Widget"')
    end
  end

  describe ".from_models" do
    it "extracts from a models directory directly" do
      models_dir = File.join(project_dir, "app", "models")
      FileUtils.mkdir_p(models_dir)
      File.write(File.join(models_dir, "item.rb"), <<~RUBY)
        class Item < ApplicationRecord
          belongs_to :category
        end
      RUBY

      dsl = Hecks::Import.from_models(models_dir, domain_name: "Store")
      expect(dsl).to include('Hecks.domain "Store"')
      expect(dsl).to include('reference_to "Category"')
    end
  end
end
