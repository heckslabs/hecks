require "spec_helper"

RSpec.describe "Attachments (HEC-165)" do
  let(:domain) do
    Hecks.domain "AttachTest" do
      aggregate "Document" do
        attribute :title, String

        command "CreateDocument" do
          attribute :title, String
        end
      end
    end
  end

  before do
    @app = Hecks.load(domain) do
      enable "Document", :attachable
    end
  end

  it "attaches file metadata and lists attachments" do
    doc = Document.create(title: "Report")
    doc.attach(name: "photo.jpg", url: "https://example.com/photo.jpg", content_type: "image/jpeg")
    doc.attach(name: "data.csv", url: "https://example.com/data.csv")

    expect(doc.attachments.size).to eq(2)
    expect(doc.attachments.first[:name]).to eq("photo.jpg")
    expect(doc.attachments.first[:content_type]).to eq("image/jpeg")
    expect(doc.attachments.last[:content_type]).to be_nil
  end

  it "returns a copy of attachments (not mutable)" do
    doc = Document.create(title: "Report")
    doc.attach(name: "file.txt", url: "https://example.com/file.txt")
    list = doc.attachments
    list.clear
    expect(doc.attachments.size).to eq(1)
  end
end
