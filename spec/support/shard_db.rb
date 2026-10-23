# frozen_string_literal: true

require "tmpdir"

# Two SQLite shards (eu, us) of an "events" table, for routing_field and
# cross-database specs. Events reference ShopDb customers, which live in
# another database.
module ShardDb
  module_function

  def setup!
    return if @ready

    dir = Dir.mktmpdir("ror_mcp_shards")
    ShardDb::Record.connects_to shards: {
      eu: { writing: { adapter: "sqlite3", database: File.join(dir, "eu.sqlite3") } },
      us: { writing: { adapter: "sqlite3", database: File.join(dir, "us.sqlite3") } },
    }
    { eu: [[1, "signup", 1], [2, "order", 2]], us: [[1, "signup", 3]] }.each do |shard, rows|
      ShardDb::Record.connected_to(shard: shard) do
        connection = ShardDb::Record.connection
        connection.create_table(:events) do |t|
          t.string :name, null: false
          t.integer :customer_id
        end
        rows.each { |id, name, customer| ShardDb::Event.create!(id: id, name: name, customer_id: customer) }
      end
    end
    @ready = true
  end

  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class Event < Record
    self.table_name = "events"
    belongs_to :customer, class_name: "ShopDb::Customer", optional: true
  end
end
