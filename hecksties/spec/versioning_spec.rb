require "spec_helper"

RSpec.describe "Aggregate versioning (HEC-164)" do
  let(:domain) do
    Hecks.domain "VersionTest" do
      aggregate "Document" do
        attribute :title, String
        attribute :content, String

        command "CreateDocument" do
          attribute :title, String
          attribute :content, String
        end

        command "UpdateDocument" do
          reference_to "Document"
          attribute :title, String
          attribute :content, String
        end
      end
    end
  end

  before do
    @app = Hecks.load(domain) do
      enable "Document", :versioned
    end
  end

  it "snapshots state before each update" do
    document = Document.create(title: "Draft", content: "Hello")
    Document.update(document: document.id, title: "Final", content: "World")

    versions = Document.versions(document.id)
    expect(versions.size).to eq(1)
    expect(versions.first[:state][:title]).to eq("Draft")
    expect(versions.first[:state][:content]).to eq("Hello")
  end

  it "tracks multiple versions" do
    document = Document.create(title: "V1", content: "First")
    Document.update(document: document.id, title: "V2", content: "Second")
    Document.update(document: document.id, title: "V3", content: "Third")

    versions = Document.versions(document.id)
    expect(versions.size).to eq(2)
    expect(versions[0][:version]).to eq(1)
    expect(versions[1][:version]).to eq(2)
    expect(versions[0][:state][:title]).to eq("V1")
    expect(versions[1][:state][:title]).to eq("V2")
  end

  it "retrieves a specific version" do
    document = Document.create(title: "Original", content: "Content")
    Document.update(document: document.id, title: "Changed", content: "New content")

    snapshot = Document.at_version(document.id, 1)
    expect(snapshot[:title]).to eq("Original")
  end

  it "returns empty for no versions" do
    document = Document.create(title: "Fresh", content: "New")
    expect(Document.versions(document.id)).to be_empty
  end
end
