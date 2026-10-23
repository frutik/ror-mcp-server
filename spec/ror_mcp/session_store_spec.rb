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
