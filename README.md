# ROR MCP Server

![License](https://img.shields.io/badge/license-MIT-blue)
![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)
![Rails](https://img.shields.io/badge/rails-%3E%3D%207.1-red)
![Version](https://img.shields.io/badge/version-0.1.1-blue)

**ROR MCP Server** (`ror-mcp-server`) lets AI agents and **MCP clients** (Claude Code,
MCP Inspector, the MCP SDKs, …) work with your **Ruby on Rails** app through the
[Model Context Protocol](https://modelcontextprotocol.io):

- 🗂 **Publish ActiveRecord models as collections.** Clients query them with a
  MongoDB-style pipeline (`$match`, `$lookup`, `$group`, …), compiled to safe, read-only SQL.
- 🛠 **Publish Ruby methods as tools**, with typed parameters and generated JSON Schema.
- 🔌 **Mount MCP servers anywhere in your routes.** They are plain Rack endpoints, built on
  the official [MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk).

It is a Rails port of [django-mcp-server](https://github.com/omarbenhamid/django-mcp-server)
by Omar BENHAMID, and speaks the same tools and query language.

> [!NOTE]
> **0.1.1**, tested in CI on Ruby 3.2–3.4, Rails 7.1–8.1 and SQLite, PostgreSQL and MySQL.
> It isn't on RubyGems yet: install it from GitHub.

---

## Contents

- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Connect a client](#connect-a-client)
- [Querying collections](#querying-collections)
- [Collections reference](#collections-reference)
- [Tools reference](#tools-reference)
- [Configuration reference](#configuration-reference)
- [Guides](#guides)
- [Development](#development)
- [License](#license)

---

## Features

- **Collections:** publish ActiveRecord models with an explicit field whitelist, a
  per-request row scope, full-text search fields, computed SQL fields and joins between
  collections.
- **One query tool per server** (`query_data_collections`): its description carries every
  collection's schema, so clients know what they can ask for. Values are always bound,
  never interpolated into SQL.
- **Tools:** Ruby methods with declared parameters. Return values become tool results, and
  exceptions become tool errors.
- **Several servers in one app,** each with its own collections, tools, instructions and
  authentication.
- **Authentication** is one block: return a context object or `nil` (401). The context
  reaches collection scopes and tools.
- **Safe by default:** queries run in a read-only transaction, with a statement timeout and
  default and maximum row limits. Tools must declare that they write.
- **Multiple databases and sharding:** `connects_to` per collection, and a routing field
  that lets the client pick the shard.
- **JSON, CSV or JSONL output,** inline or as an embedded resource.
- **Instrumentation** through `ActiveSupport::Notifications`.
- **Generators and rake tasks** to scaffold servers, inspect them, and validate them in CI.

---

## Installation

```ruby
# Gemfile
gem "ror-mcp-server", github: "frutik/ror-mcp-server", tag: "v0.1.1"
```

```sh
bundle install
```

Leave out `tag:` to follow `main`.

Requirements: Ruby ≥ 3.2, Rails ≥ 7.1, and SQLite, PostgreSQL or MySQL.

---

## Quick start

### 1. Install

```sh
bin/rails generate ror_mcp:install
```

This creates `config/initializers/ror_mcp.rb`, mounts the server at `/mcp` and creates
`app/mcp/`, where collections and tools live:

```ruby
# config/initializers/ror_mcp.rb
RorMcp.configure do |c|
  c.default_server name: "myapp", instructions: "Data of MyApp. Query it with query_data_collections."

  # Every request must carry "Authorization: Bearer <MCP_TOKEN>"; anything else gets 401.
  c.authenticate do |request|
    token = request.authorization.to_s.delete_prefix("Bearer ")
    ActiveSupport::SecurityUtils.secure_compare(token, ENV.fetch("MCP_TOKEN")) && { client: :mcp }
  end
end
```

This uses one shared token. For per-user tokens and how the returned context is used, see
[Authentication](#authentication).

```ruby
# config/routes.rb
mount RorMcp::Engine, at: "/mcp"
```

### 2. Publish models

```sh
bin/rails generate ror_mcp:collection Order --fields id number status total customer placed_at
bin/rails generate ror_mcp:collection Customer --fields id name country
```

```ruby
# app/mcp/order_collection.rb
class OrderCollection < RorMcp::Collection
  model  Order
  fields :id, :number, :status, :total, :customer, :placed_at
  instructions "One row per order. Latest = highest id."

  def scope(context)                       # the rows this collection exposes
    Order.where(account: context[:user].account)
  end
end
```

`fields` is required; `fields :all` publishes every column. `customer` is a `belongs_to`.
Because customers are published too, clients can join orders to customers with `$lookup`.

### 3. Publish tools

```sh
bin/rails generate ror_mcp:toolset Orders
```

```ruby
# app/mcp/orders_tools.rb
class OrdersTools < RorMcp::Toolset
  tool :order_count, description: "Number of orders placed by a customer" do
    param :customer_id, :integer, required: true
  end

  def order_count(customer_id:)
    Order.where(customer_id: customer_id).count
  end

  tool :flag_order, writes: true, description: "Flag an order for review" do
    param :order_id, :integer, required: true
    param :reason,   :string,  required: true
  end

  def flag_order(order_id:, reason:)
    Order.find(order_id).update!(flagged: true, flag_reason: reason)
    { flagged: order_id }
  end
end
```

### 4. Check it

```sh
bin/rails ror_mcp:describe     # servers, tools, collections, description sizes
bin/rails ror_mcp:check        # validates everything; exits 1 on a problem (use it in CI)
```

The server answers at `http://localhost:3000/mcp`.

---

## Connect a client

> [!IMPORTANT]
> For data that isn't public, configure [authentication](#authentication) first.

**Claude Code**

```sh
claude mcp add --transport http myapp http://localhost:3000/mcp --header "Authorization: Bearer <token>"
```

**MCP Inspector**

```sh
npx @modelcontextprotocol/inspector
```

Choose transport **Streamable HTTP**, enter `http://localhost:3000/mcp`, and add your
`Authorization` header.

**MCP Python SDK**

```python
import asyncio
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def main():
    async with streamablehttp_client("http://localhost:3000/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool("query_data_collections", {
                "collection": "order",
                "search_pipeline": [{"$sort": {"id": -1}}, {"$limit": 5}],
            })
            print(result.content[0].text)

asyncio.run(main())
```

**curl**

```sh
curl -si http://localhost:3000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

The response is plain JSON (never an SSE stream) with an `Mcp-Session-Id` header. Send
that header with every later request.

Only the Streamable HTTP transport is supported; clients that speak only stdio need an
HTTP bridge.

---

## Querying collections

### The tools

Every server publishes `get_server_instructions`, and, when it has collections:

```
query_data_collections(collection: string, search_pipeline: object[] = [])
```

The tool's description explains the pipeline syntax and lists every collection with its
`$jsonSchema`: field types, references to other collections, enum values and descriptions.
Collection names default to the model's singular name (`order`, `line_item`) and can be
set with `collection_name`.

### Stages

| Stage | What it does |
|---|---|
| `$match` | Filters. A literal value means equality. Operators: `$eq $ne $gt $gte $lt $lte $in $nin $regex`, `$and $or $nor`, and any operator a collection enables with `extra_filters`. `null` matches NULL. `_id` is the primary key. |
| `$match: {$text: {$search: "…"}}` | Full-text search: every word must match at least one search field, case-insensitively. |
| `$search: {text: {query, path?}}` | The same search, optionally limited to some search fields. |
| `$lookup` | Joins a `belongs_to` target: `{from, localField, foreignField: "_id", as}`. Later stages use `as.field`. A reference joins one collection per query: two `$lookup`s may share it only with the same `from`. |
| `$sort` | `{field: 1}` ascending, `{field: -1}` descending. Lookup aliases work: `{"c.name": 1}`. |
| `$skip` / `$limit` | Pagination, applied in pipeline order. |
| `$project` | `{field: 1}` includes, `{field: 0}` excludes, `{"key": "$field"}` or `{"key": "$alias.field"}` renames. Dotted keys produce nested objects. |
| `$group` | Last stage. `_id` is `null`, `"$field"` or `{key: "$field", …}`. Accumulators: `$sum $avg $min $max $count`. |

Any other stage (`$unwind`, `$addFields`, …) is rejected with an error explaining what's
supported. Errors come back as tool errors, written for the client to correct its query.

### Examples

Join orders to customers:

```json
[{"$lookup": {"from": "customer", "localField": "customer", "foreignField": "_id", "as": "c"}},
 {"$sort": {"id": 1}}, {"$limit": 2},
 {"$project": {"number": 1, "customer_name": "$c.name", "customer_country": "$c.country"}}]
```
```json
[{"number":"ORD-1001","customer_name":"Bram Peeters","customer_country":"BE"},
 {"number":"ORD-1002","customer_name":"Bram Peeters","customer_country":"BE"}]
```

Revenue per status:

```json
[{"$group": {"_id": "$status", "n": {"$sum": 1}, "revenue": {"$sum": "$total"}}}]
```
```json
[{"n":4,"revenue":9267.4,"status":"cancelled"},{"n":3,"revenue":11804.98,"status":"paid"},
 {"n":4,"revenue":8228.48,"status":"pending"},{"n":3,"revenue":6273.74,"status":"shipped"}]
```

Full-text search:

```json
[{"$match": {"$text": {"$search": "laptop"}}}, {"$sort": {"sku": 1}}, {"$project": {"sku": 1, "name": 1}}]
```
```json
[{"sku":"LAP-001","name":"ThinkBook 14 laptop"},{"sku":"LAP-002","name":"Gaming laptop Pro"},
 {"sku":"LAP-003","name":"Budget laptop"}]
```

### Results

Rows come back as one JSON text content. Without `$project`, a row holds the collection's
`fields`, with foreign keys as `<name>_id`. Decimals are numbers, and datetimes are ISO 8601
in UTC. An empty result is `[]`. Queries without `$limit` get `default_limit` rows (100),
and no query gets more than `max_limit` (1000). See [Output formats](#output-formats) for
CSV, JSONL and embedded resources.

---

## Collections reference

```ruby
class Sales::OrderCollection < RorMcp::Collection
  server :sales                             # default: the default server
  model  Order
  collection_name "order"                   # default: the model's singular name
  fields :id, :number, :status, :total, :currency, :customer, :placed_at   # required (or :all)
  exclude_fields :internal_notes            # useful with fields :all
  search_fields :number                     # default: string/text columns within fields
  extra_filters :icontains, :startswith     # extra $match operators clients may use
  max_limit 500                             # default: config.max_limit
  output_format :json                       # :json | :csv | :jsonl
  output_as_resource false                  # true → results attached as an embedded resource

  description "One row per order placed by a customer."   # top of the schema
  describe :total, "Order total in EUR"                   # a field's description
  choice_labels :currency, "EUR" => "Euro", "USD" => "US dollar"   # labels for enum values

  computed :line_count, :integer,
           sql: "SELECT count(*) FROM line_items WHERE line_items.order_id = {table}.id",
           doc: "number of line items in the order"

  reference :customer, to: "customer"       # target collection, when it can't be inferred
  connects_to role: :reading                # role/shard for this collection's queries

  instructions <<~TXT
    One row per order. "status": pending, paid, shipped, cancelled.
    "customer" references the customer collection. Latest = highest id.
  TXT

  def scope(context)                        # the rows this collection exposes
    Order.all
  end
end
```

| Option | Meaning |
|---|---|
| `server` | Which server publishes the collection. The same model can be published on several servers. |
| `model` | The ActiveRecord model. |
| `collection_name` | The name clients use. Two collections can't share a name on one server. |
| `fields` | Published columns and `belongs_to` associations. Only these can be filtered, sorted, projected or grouped, also through `$lookup`. Required, so wide models don't bloat the description by accident. |
| `exclude_fields` | Fields to leave out. |
| `search_fields` | Columns used by `$text` / `$search`. |
| `extra_filters` | Extra `$match` operators: `contains`, `icontains`, `startswith`, `istartswith`, `endswith`, `iendswith`, `iexact`, `iregex`, `range`, `date`, `year`, `month`, `day`, `hour`, `minute`, `second`, `week_day`, `quarter`. Use as `{"number": {"$icontains": "x"}}`. |
| `computed` | A SQL expression published as a field: in the schema, and usable in every stage, also through `$lookup`. `{table}` stands for the collection's table (or its join alias). |
| `reference` | Where a `belongs_to` points, when it can't be inferred. Subclasses (STI) are resolved automatically. |
| `max_limit` | Upper bound on `$limit` for this collection. |
| `description`, `describe`, `choice_labels` | Text for the schema. Defaults: `Model(field, …)`, the column comment, the humanized enum key. |
| `instructions` | Extra text after the collection's schema in the tool description. |
| `output_format`, `output_as_resource` | See [Output formats](#output-formats). |
| `connects_to`, `routing_field` | See [Multiple databases and sharding](#multiple-databases-and-sharding). |
| `abstract!` | A shared base class, never published itself; subclasses inherit its settings. |
| `scope(context)` | The relation queries start from. `context` is what `authenticate` returned. A `$lookup` into this collection sees the same rows. A `limit` or `offset` in it bounds the rows too: pipeline stages filter, sort and page within them. |

The schema comes from the model: column types become `bsonType`, `belongs_to` becomes a
reference to the target collection, `enum` becomes `enum`, and non-null columns become
`required`.

---

## Tools reference

```ruby
class Sales::CatalogSearchTools < RorMcp::Toolset
  server :sales

  tool :search_products, description: "Full-text search over the product catalog" do
    param :query,  :string,  required: true, desc: "search terms"
    param :brands, [:string]
    param :limit,  :integer, default: 20
  end

  def search_products(query:, brands: nil, limit: 20)
    ProductSearch.call(query:, brands:, limit:)
  end

  tool :latest_order, description: "The most recent order", serialize_with: OrderSerializer

  def latest_order
    Order.order(id: :desc).first
  end
end
```

- Each tool needs an instance method of the same name. Parameter types: `:string`,
  `:integer`, `:number`, `:boolean`, `:object`, and arrays as `[:type]`.
- Each call gets a new instance, with `context` (from `authenticate`) and `request` available.
- Return values: a string as-is, an array as one result per element, anything else as JSON
  indented by 2, and `nil` as no content. An `ActiveRecord::Relation` is loaded first. An
  `MCP::Tool::Response` passes through unchanged.
- `serialize_with:` shapes the return value first. It takes a callable, a Blueprinter-style
  class (`render_as_hash`), or a serializer class (`new(value).as_json`).
- Exceptions become tool errors ("Error executing tool …") with the message.
- Tools run read-only. A tool that writes must declare `writes: true`.

---

## Configuration reference

```ruby
RorMcp.configure do |c|
  c.default_server name: "myapp", instructions: "…", stateless: false
  c.server :reports, name: "myapp-reports", instructions: "…", stateless: true,
           authenticate: ->(request) { … }   # per server: a callable, or false for none

  c.authenticate { |request| … }      # global: return a context or nil (401)
  c.session_store      = :memory      # :memory | :cache (Rails.cache) | object with create/exists?/delete
  c.instructions_tool  = true         # publish get_server_instructions

  c.read_role          = nil          # e.g. :reading, to run queries on a replica
  c.statement_timeout  = nil          # e.g. 15.seconds (PostgreSQL, MySQL)
  c.default_limit      = 100          # rows when a pipeline has no $limit
  c.max_limit          = 1000         # upper bound on $limit
  c.description_budget = nil          # characters per server's query tool description
  c.description_budget_mode = :warn   # or :raise

  c.on_query { |event| … }            # after each query
  c.on_tool  { |event| … }            # after each tool call

  c.pipeline_semantics = :fixed       # :parity is a compatibility mode, see DEVELOPMENT.md
end
```

---

## Guides

### Multiple servers

```ruby
# config/initializers/ror_mcp.rb
RorMcp.configure do |c|
  c.default_server name: "myapp-catalog", instructions: "…"
  c.server :sales,   name: "myapp-sales",   instructions: "…"
  c.server :support, name: "myapp-support", instructions: "…", stateless: true
end
```

```ruby
# config/routes.rb — mounts match by prefix in order, so longer paths go first
mount RorMcp.endpoint(:sales),   at: "/mcp/sales"
mount RorMcp.endpoint(:support), at: "/mcp/support"
mount RorMcp::Engine,            at: "/mcp"   # the default server
```

Collections and toolsets choose their server with `server :sales`. Collections are
registered by server and name, not by class name, so classes in different modules never clash.

### Authentication

The gem doesn't manage credentials; you decide who may connect. On every MCP request, the
`authenticate` block receives the `ActionDispatch::Request`:

- Return `nil` or `false`, and the client gets `401` with `WWW-Authenticate: Bearer`.
  Nothing else runs.
- Return anything else, for example `{ user: user }`, and the request goes through.
  That value is the **context**: it's passed to every collection's `scope(context)` and
  is available as `context` in tools, so results can depend on who is asking.

Without `c.authenticate`, the server is open to anyone who can reach it.

Clients send the token as a header, for example:

```sh
claude mcp add --transport http myapp https://myapp.example/mcp --header "Authorization: Bearer <token>"
```

**One shared token** (personal or internal servers):

```ruby
c.authenticate do |request|
  token = request.authorization.to_s.delete_prefix("Bearer ")
  ActiveSupport::SecurityUtils.secure_compare(token, ENV.fetch("MCP_TOKEN")) && { client: :mcp }
end
```

**A token per user.** `ApiKey` here is a model in *your* app, not part of the gem:

```sh
bin/rails g model ApiKey user:references token_digest:string:uniq
```

```ruby
class ApiKey < ApplicationRecord
  belongs_to :user

  # Show the returned token to the user once; only its digest is stored.
  def self.issue!(user)
    token = SecureRandom.hex(32)
    create!(user: user, token_digest: Digest::SHA256.hexdigest(token))
    token
  end

  def self.authenticate(token)
    token.present? && find_by(token_digest: Digest::SHA256.hexdigest(token))
  end
end
```

```ruby
c.authenticate do |request|
  key = ApiKey.authenticate(request.authorization.to_s.delete_prefix("Bearer "))
  key && { user: key.user }
end
```

```ruby
class OrderCollection < RorMcp::Collection
  model Order
  fields :id, :number, :total
  def scope(context) = Order.where(account: context[:user].account)   # each caller sees only their orders
end
```

**Existing authentication:** if your users already have API tokens (a column, Devise token
auth, …), look the user up the same way and return `{ user: user }`.

**Per server:** `c.authenticate` applies to every server unless a server sets its own:

```ruby
c.server :partners, name: "partners", authenticate: ->(request) { Partner.authenticate(request) }
c.server :public,   name: "public",   authenticate: false   # no authentication on this one
```

Endpoints are plain Rack apps: no cookies and no CSRF checks. Host checks are left to
Rails' `config.hosts`, so make sure the host your clients use is allowed.

### Sessions

Servers are stateful by default:

- `initialize` without a session gets a new `Mcp-Session-Id`.
- Any other request without one gets `400`, and an unknown or expired id gets `404`.
- `DELETE` ends the session.

`:memory` sessions live in one process. With several Puma workers or hosts, use
`session_store = :cache` with a shared cache (Redis, Memcached, Solid Cache), or
`stateless: true` on the server, which skips sessions entirely.

### Output formats

```ruby
output_format :csv           # :json (default) | :csv | :jsonl
output_as_resource true      # reply "Results attached" plus the data as an embedded resource
```

CSV has a sorted header, flattens nested values into dotted columns (`metadata.channel`),
and uses `\r\n` line endings.

### Computed fields

Values that live in SQL rather than in a column. They appear in the schema and work in
every stage, including from another collection through `$lookup`. `{table}` is replaced by
the table name, or by the join alias:

```ruby
computed :line_count, :integer,
         sql: "SELECT count(*) FROM line_items WHERE line_items.order_id = {table}.id",
         doc: "number of line items in the order"
```

### Safety

Every query, and every tool not declared `writes: true`, runs in an envelope that never
changes results, only stops unsafe ones:

```ruby
connected_to(role: read_role, shard: …) {        # when configured
  while_preventing_writes { transaction {        # Rails refuses write statements
    # PostgreSQL: SET TRANSACTION READ ONLY; SET LOCAL statement_timeout
    # MySQL:      SET SESSION max_execution_time
    # SQLite:     PRAGMA query_only
    …                                            # rolled back at the end
} } }
```

For defence in depth, also give the database user that serves MCP read-only grants.

### Multiple databases and sharding

A collection runs on its model's database. Pin a role or shard with `connects_to`, or let
the client pick the shard with a routing field:

```ruby
class Billing::InvoiceCollection < RorMcp::Collection
  model Invoice                         # Invoice < BillingRecord, which connects_to its database
  connects_to role: :reading
  fields :all
end

class Analytics::EventCollection < RorMcp::Collection
  model Event
  fields :id, :name, :occurred_at
  routing_field :region, to: ->(value) { %w[eu us].include?(value) ? { shard: value.to_sym } : nil }
end
```

- References into another database are left out of the schema, and a `$lookup` across
  databases is refused.
- A routing field appears in the schema and is required as an equality in `$match`
  (`{"region": "eu"}`). The query then runs under `connected_to(shard: :eu)`. `to`
  returning `nil` means "no such shard". The field can't be sorted, projected, grouped or
  joined.

### Description size

The `query_data_collections` description contains every collection's schema. If it gets
too long, some clients truncate it and silently lose collections. Keep `fields` narrow,
watch `bin/rails ror_mcp:describe`, and set `description_budget` to get a warning, or an
error with `description_budget_mode = :raise`.

### Instrumentation

| Event | Payload |
|---|---|
| `query.ror_mcp` | server, collection, pipeline, rows (count), error |
| `tool.ror_mcp` | server, tool, error |

```ruby
c.on_query { |event| Rails.logger.info(event.to_h.to_json) }   # name, server, collection, pipeline, rows, duration_ms, error
c.on_tool  { |event| StatsD.timing("mcp.tool.#{event.tool}", event.duration_ms) }
```

### Generators and rake tasks

```sh
bin/rails g ror_mcp:install                                              # initializer, route, app/mcp/
bin/rails g ror_mcp:collection Sales::Order --server sales --fields id number status [--model Order]
bin/rails g ror_mcp:toolset Sales::CatalogSearch [--server sales]
bin/rails "ror_mcp:describe[sales]"                                      # one server, or all without [ ]
bin/rails ror_mcp:check                                                  # exits 1 on problems
```

---

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for the repository layout, running the tests on each
database, the compatibility test suite, and the project's status.

---

## License

MIT, see [LICENSE](LICENSE).
