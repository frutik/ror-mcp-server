# frozen_string_literal: true

require "active_support"
require "active_support/cache"

RSpec.describe RorMcp::SessionStore do
  shared_examples "a session store" do
    it "creates distinct ids that exist until deleted" do
      a = store.create
      b = store.create
      expect(a).not_to eq(b)
      expect(store.exists?(a)).to be(true)
      store.delete(a)
      expect(store.exists?(a)).to be(false)
      expect(store.exists?(b)).to be(true)
    end

    it "does not know ids it never issued" do
      expect(store.exists?("nope")).to be(false)
    end
  end

  describe RorMcp::SessionStore::Memory do
    subject(:store) { described_class.new }

    it_behaves_like "a session store"

    it "expires sessions" do
      now = 0
      store = described_class.new(expires_in: 60, clock: -> { now })
      id = store.create
      now = 59
      expect(store.exists?(id)).to be(true)
      now = 60
      expect(store.exists?(id)).to be(false)
      expect(store.size).to eq(0)
    end

    it "drops expired sessions as new ones arrive, and the oldest past max" do
      now = 0
      store = described_class.new(expires_in: 60, max: 3, clock: -> { now })
      first, second, third = Array.new(3) { store.create.tap { now += 1 } }
      fourth = store.create
      expect([first, second, third, fourth].map { |id| store.exists?(id) }).to eq([false, true, true, true])
      expect(store.size).to eq(3)
      now = 1000
      store.create
      expect(store.size).to eq(1)
    end
  end

  describe RorMcp::SessionStore::Cache do
    subject(:store) { described_class.new(cache: ActiveSupport::Cache::MemoryStore.new) }

    it_behaves_like "a session store"

    it "expires sessions" do
      cache = ActiveSupport::Cache::MemoryStore.new
      id = described_class.new(cache: cache, expires_in: 60).create
      expect(cache.exist?("ror_mcp:session:#{id}")).to be(true)
      allow(Time).to receive(:now).and_return(Time.at(Time.now.to_f + 61))
      expect(cache.exist?("ror_mcp:session:#{id}")).to be(false)
    end
  end

  describe ".build" do
    it "maps settings to stores" do
      expect(described_class.build(:memory)).to be_a(RorMcp::SessionStore::Memory)
      expect(described_class.build(:cache)).to be_a(RorMcp::SessionStore::Cache)
      custom = Object.new
      expect(described_class.build(custom)).to be(custom)
      expect { described_class.build(:redis) }.to raise_error(RorMcp::ConfigurationError)
    end
  end
end
