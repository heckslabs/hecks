require "spec_helper"
require "tmpdir"
require "fileutils"
require "sequel"

RSpec.describe "Hecks.boot with SQL adapter" do
  let(:tmpdir) { Dir.mktmpdir("hecks-sql-boot-") }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_domain(dir, content)
    File.write(File.join(dir, "PizzasBluebook"), content)
  end

  it "boots with :sqlite and returns a Runtime" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "SqlTest" do
        aggregate "Widget" do
          attribute :name, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end
    RUBY

    app = Hecks.boot(tmpdir, adapter: :sqlite)
    expect(app).to be_a(Hecks::Runtime)
    expect(app.domain.name).to eq("SqlTest")
  end

  it "persists data through SQL create, find, count" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "SqlPersist" do
        aggregate "Item" do
          attribute :title, String
          attribute :qty, Integer
          command "CreateItem" do
            attribute :title, String
            attribute :qty, Integer
          end
        end
      end
    RUBY

    app = Hecks.boot(tmpdir, adapter: :sqlite)
    item = Item.create(title: "Bolt", qty: 10)
    expect(item.title).to eq("Bolt")
    expect(item.qty).to eq(10)

    found = Item.find(item.id)
    expect(found).not_to be_nil
    expect(found.title).to eq("Bolt")
    expect(found.qty).to eq(10)

    expect(Item.count).to eq(1)
  end

  it "supports file-based SQLite via hash config" do
    db_path = File.join(tmpdir, "test.db")
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "SqlFile" do
        aggregate "Note" do
          attribute :body, String
          command "CreateNote" do
            attribute :body, String
          end
        end
      end
    RUBY

    app = Hecks.boot(tmpdir, adapter: { type: :sqlite, database: db_path })
    Note.create(body: "Hello")
    expect(Note.count).to eq(1)
    expect(File.exist?(db_path)).to be true
  end

  it "handles Float and reference attributes" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "SqlTypes" do
        aggregate "Owner" do
          attribute :name, String
          command "CreateOwner" do
            attribute :name, String
          end
        end

        aggregate "Product" do
          reference_to "Owner"
          attribute :price, Float
          command "CreateProduct" do
            reference_to "Owner", validate: :exists
            attribute :price, Float
          end
        end
      end
    RUBY

    app = Hecks.boot(tmpdir, adapter: :sqlite)
    owner = Owner.create(name: "Acme")
    product = Product.create(owner: owner.id, price: 9.99)
    found = Product.find(product.id)
    expect(found.price).to eq(9.99)
    expect(found.owner.id).to eq(owner.id)
  end
end
