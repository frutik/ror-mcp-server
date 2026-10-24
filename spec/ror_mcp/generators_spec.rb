# frozen_string_literal: true

require "tmpdir"
require "rails/generators"
require_relative "../../lib/generators/ror_mcp/install/install_generator"
require_relative "../../lib/generators/ror_mcp/collection/collection_generator"
require_relative "../../lib/generators/ror_mcp/toolset/toolset_generator"

RSpec.describe "generators" do
  around do |example|
    Dir.mktmpdir("ror_mcp_generators") do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  def run(generator, *args)
    generator.start(args, destination_root: @root, quiet: true)
  end

  def read(path) = File.read(File.join(@root, path))

  it "ror_mcp:install creates the initializer, mounts the engine and creates app/mcp" do
    run(RorMcp::Generators::InstallGenerator)
    expect(read("config/initializers/ror_mcp.rb")).to include("RorMcp.configure do |c|", "c.default_server name:")
    expect(read("config/routes.rb")).to include('mount RorMcp::Engine, at: "/mcp"')
    expect(File).to exist(File.join(@root, "app/mcp/.keep"))
  end

  it "ror_mcp:collection writes a namespaced collection with fields and server" do
    run(RorMcp::Generators::CollectionGenerator, "Sales::Order", "--fields", "id", "number", "customer", "--server", "sales")
    expect(read("app/mcp/sales/order_collection.rb")).to eq(<<~'RUBY')
      class Sales::OrderCollection < RorMcp::Collection
        server :sales
        model Sales::Order
        fields :id, :number, :customer
        # description "What one row is."                 # schema description clients see
        # instructions <<~'TXT'                          # quoted: "#$x" in pipeline examples stays literal
        #   When to query this collection, and what the values mean.
        # TXT
        # search_fields :name                            # $text / $search (default: string columns in fields)

        # Rows this collection exposes; context comes from the authenticate block.
        # def scope(context)
        #   Sales::Order.all
        # end
      end
    RUBY
  end

  it "ror_mcp:collection defaults to all fields and can name another model" do
    run(RorMcp::Generators::CollectionGenerator, "Customer", "--model", "Account")
    source = read("app/mcp/customer_collection.rb")
    expect(source).to include("model Account", "fields :all")
    expect(source).not_to include("server :")
  end

  it "ror_mcp:toolset writes a toolset with an example tool" do
    run(RorMcp::Generators::ToolsetGenerator, "CatalogSearch")
    source = read("app/mcp/catalog_search_tools.rb")
    expect(source).to start_with("class CatalogSearchTools < RorMcp::Toolset\n  tool :example")
    expect(source).to include("def example(query:)")
  end
end

RSpec.describe RorMcp::Inspector do
  before do
    ShopDb.setup!
    RorMcp.configure { |c| c.default_server name: "shop", instructions: "Shop data." }
    define_collection("OrderCollection") { model ShopDb::Order; collection_name "order"; fields :id, :number }
  end

  after { RorMcp.reset! }

  it "describes servers, tools and the description size" do
    io = StringIO.new
    RorMcp.configuration.description_budget = 50
    described_class.describe(io: io)
    expect(io.string).to include("default: shop", 'instructions: "Shop data."', "tool get_server_instructions",
                                 "tool query_data_collections", "collections: order (ShopDb::Order)",
                                 "of a 50 budget — OVER")
  end

  it "checks collections and budgets" do
    io = StringIO.new
    expect(described_class.check(io: io)).to be(true)
    expect(io.string).to include("✓ 1 MCP server(s) OK")

    define_collection("Broken") { model ShopDb::Customer; collection_name "broken"; fields :nope }
    RorMcp.configuration.description_budget = 10
    io = StringIO.new
    expect(described_class.check(io: io)).to be(false)
    expect(io.string).to include("✗ default: Broken: fields nope not found", "over the budget of 10")
  end
end
