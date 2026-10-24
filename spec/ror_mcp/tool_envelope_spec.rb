# frozen_string_literal: true

# A second database, reached through its own abstract class (multi-database apps).
module EnvelopeSpec
  class OtherRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  class Note < OtherRecord
    self.table_name = "notes"
  end

  # Names a connection that has no pool (a connects_to whose database is missing).
  class UnconnectedRecord < ActiveRecord::Base
    self.abstract_class = true
    self.connection_specification_name = "EnvelopeSpec::UnconnectedRecord"
  end

  def self.connect!
    return if @connected

    OtherRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    OtherRecord.connection.create_table(:notes) { |t| t.string :body }
    @connected = true
  end
end

# Tools not declared `writes: true` run read-only (PLAN §5): Rails refuses
# writes on every model, and each declared database gets a rolled-back
# read-only transaction too.
RSpec.describe "read-only tools" do
  before do
    ShopDb.setup!
    EnvelopeSpec.connect!
    EnvelopeSpec::Note.delete_all
    EnvelopeSpec::Note.create!(id: 1, body: "original")
  end

  after { RorMcp.reset! }

  def toolset(databases: [], &body)
    klass = Class.new(RorMcp::Toolset)
    stub_const("EnvelopeTools", klass)
    klass.databases(*databases) unless databases.empty?
    klass.tool(:run, description: "Runs the body.")
    klass.define_method(:run, &body)
    klass
  end

  def call(klass)
    klass.call(klass.tools.fetch("run"), {}, nil)
  end

  def note = EnvelopeSpec::Note.find(1).body

  it "refuses a write through ActiveRecord::Base" do
    response = call(toolset { ShopDb::Customer.where(id: 1).update_all(name: "Changed") })
    expect(response.error?).to be(true)
    expect(ShopDb::Customer.find(1).name).to eq("Anna")
  end

  it "refuses a write to another database, declared or not" do
    expect(call(toolset { EnvelopeSpec::Note.update_all(body: "changed") }).error?).to be(true)
    expect(call(toolset(databases: [EnvelopeSpec::OtherRecord]) { EnvelopeSpec::Note.update_all(body: "changed") }).error?).to be(true)
    expect(note).to eq("original")
  end

  it "runs a declared database's work in a transaction the database itself keeps read-only" do
    # A tool that switches Rails' guard off: only the declared database's own guard remains.
    bypass = -> { ActiveRecord::Base.while_preventing_writes(false) { EnvelopeSpec::Note.update_all(body: "changed") } }

    expect(call(toolset(databases: [EnvelopeSpec::OtherRecord]) { bypass.call }).error?).to be(true)
    expect(note).to eq("original")
    expect(call(toolset(databases: [EnvelopeSpec::OtherRecord]) { EnvelopeSpec::Note.connection.transaction_open? }).content)
      .to eq([{ type: "text", text: "true" }])

    # Undeclared, nothing but Rails' guard stands in the way.
    call(toolset { bypass.call })
    expect(note).to eq("changed")
  end

  it "fails the call when a declared database has no connection" do
    response = call(toolset(databases: [EnvelopeSpec::UnconnectedRecord]) { "ran" })
    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("no connection for EnvelopeSpec::UnconnectedRecord")
  end

  it "runs a declared class that shares ActiveRecord::Base's connection under Base's guard" do
    expect(call(toolset(databases: [ShopDb::Record]) { ShopDb::Customer.count }).content).to eq([{ type: "text", text: "3" }])
    expect(call(toolset(databases: [ShopDb::Record]) { ShopDb::Customer.update_all(name: "x") }).error?).to be(true)
  end

  it "rejects databases that aren't ActiveRecord classes" do
    expect { toolset(databases: ["OtherRecord"]) { nil }.validate! }
      .to raise_error(RorMcp::ConfigurationError, /databases takes ActiveRecord classes/)
  end

  context "without an ActiveRecord::Base connection" do
    around do |example|
      config = ActiveRecord::Base.remove_connection
      example.run
    ensure
      ActiveRecord::Base.establish_connection(config)
      ShopDb.reset! # an in-memory database is gone with its connection
    end

    it "still refuses writes on every model" do
      response = call(toolset { EnvelopeSpec::Note.update_all(body: "changed") })
      expect(response.error?).to be(true)
      expect(note).to eq("original")
    end
  end
end
