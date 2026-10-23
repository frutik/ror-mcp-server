# frozen_string_literal: true

RSpec.describe RorMcp::Configuration do
  subject(:config) { described_class.new }

  it "declares a default server named like django-mcp-server's" do
    expect(config.server_config(:default).to_h).to include(name: "ror_mcp_server", instructions: nil, stateless: false)
  end

  it "replaces the default server's settings" do
    config.default_server name: "shop", instructions: "Hi", stateless: true
    expect(config.server_config(:default).to_h).to include(name: "shop", instructions: "Hi", stateless: true)
  end

  it "names other servers after their key unless given a name" do
    config.server :sales
    expect(config.server_config("sales").name).to eq("sales")
  end

  it "lists declared servers when an unknown one is requested" do
    config.server :sales
    expect { config.server_config(:nope) }.to raise_error(RorMcp::ConfigurationError, /:nope.*default, sales/)
  end

  describe "#authenticator_for" do
    let(:global) { ->(_) { :global } }
    let(:own) { ->(_) { :own } }

    before { config.authenticate(&global) }

    it "inherits the global block" do
      expect(config.authenticator_for(config.server(:a))).to be(global)
    end

    it "prefers the server's own" do
      expect(config.authenticator_for(config.server(:b, authenticate: own))).to be(own)
    end

    it "is disabled with authenticate: false" do
      expect(config.authenticator_for(config.server(:c, authenticate: false))).to be_nil
    end
  end

  it "accepts only known pipeline semantics" do
    config.pipeline_semantics = "parity"
    expect(config.pipeline_semantics).to eq(:parity)
    expect { config.pipeline_semantics = :loose }.to raise_error(RorMcp::ConfigurationError)
  end
end

RSpec.describe RorMcp do
  after { described_class.reset! }

  it "builds each server once, so sessions survive between requests" do
    expect(described_class.server(:default)).to be(described_class.server(:default))
  end

  it "rebuilds servers after configure" do
    before = described_class.server(:default)
    described_class.configure { |c| c.default_server name: "x" }
    expect(described_class.server(:default)).not_to be(before)
    expect(described_class.server(:default).name).to eq("x")
  end

  it "finds a server declared after the servers were built" do
    described_class.server(:default)
    described_class.configuration.server(:late)
    expect(described_class.server(:late).name).to eq("late")
  end

  it "raises for an undeclared server" do
    expect { described_class.server(:nope) }.to raise_error(RorMcp::ConfigurationError)
  end
end
