# ROR MCP Server

![License](https://img.shields.io/badge/license-MIT-blue)
![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)
![Rails](https://img.shields.io/badge/rails-%3E%3D%207.1-red)
![Status](https://img.shields.io/badge/status-pre--release-orange)

**ROR MCP Server** (`ror-mcp-server`) brings the **Model Context Protocol (MCP)** to
**Ruby on Rails**. It is a port of
[django-mcp-server](https://github.com/omarbenhamid/django-mcp-server): **MCP clients**
and **AI agents** can query your Rails app's data and call its logic through MCP.

🚀 Publish ActiveRecord models as queryable collections in a few lines, safely.<br/>
🚀 Query them with a MongoDB-style aggregation pipeline (`$match`, `$lookup`, `$group`, …).<br/>
🚀 Publish plain Ruby methods as MCP tools with a small declarative DSL.<br/>
✅ Mount one or several MCP servers anywhere in your routes, as plain Rack endpoints.<br/>
✅ Same tool names, description format and query semantics as django-mcp-server, so client prompts carry over.<br/>
🤖 Any MCP client that speaks Streamable HTTP (Claude Code, MCP Inspector, the MCP SDKs, …) can connect.

Built on the official [MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk) (`mcp` gem).

Licensed under the **MIT License**.

---

> [!IMPORTANT]
> **Pre-release: most of the API below is the target, not yet the implementation.**
> Milestones **M1–M2** are done: servers, the Rack endpoint, authentication, sessions,
> collections and `query_data_collections` with `$match $sort $skip $limit $project` work.
> `$lookup` is next, then `$group`/search and tools. Features are built milestone
> by milestone (see [Project status](#project-status)), and each section is marked with the
> milestone that delivers it. The design lives in
> [`PLAN.md`](PLAN.md).

---

## Contents

- [Project status](#project-status)
- [Features](#features)
- [Quick start](#quick-start)
- [Verify your setup](#verify-your-setup)
- [Use with an MCP client](#use-with-an-mcp-client)
- [Querying collections](#querying-collections)
- [Collections reference](#collections-reference)
- [Tools reference](#tools-reference)
- [Advanced topics](#advanced-topics)
- [Coming from django-mcp-server](#coming-from-django-mcp-server)
- [Development](#development)
- [License](#license)

---

## Project status

| Milestone | Delivers | Status |
|---|---|---|
| **M0** | Gemspec, Django reference app + recorded golden output, Rails dummy app, parity client, transport spike | ✅ done (CI matrix open) |
| **M1** | `RorMcp::Server`, `RorMcp::Endpoint`, authentication, session stores, `get_server_instructions` | ✅ done: the Rails app matches all 11 recorded HTTP/session scenarios |
| **M2** | Collection DSL, schema generation, `query_data_collections` with `$match $sort $skip $limit $project` | ✅ done: descriptions match Django byte for byte; 78/120 parity cases pass |
| **M3** | `$lookup`, references, multiple servers | planned |
| **M4** | `$group`, `$text`/`$search`, `extra_filters`, computed fields | planned |
| **M5** | Toolset DSL, write tools, JSON/CSV output, `serialize_with` | planned |
| **M6** | Read-only safety envelope, multi-database, sharding, description budget, instrumentation, `:fixed` semantics | planned |
| **M7** | Generators, rake tasks, first release (0.1.0) | planned |

How "done" is decided: a reference Django app runs django-mcp-server on a small shop
schema, and its answers to a 107-case corpus are recorded. The Rails dummy app, with the
same schema and data, has to return the same answers. See [Development](#development).

---

## Features

- Expose ActiveRecord models as MCP **collections** with an explicit field whitelist. *(M2)*
- One `query_data_collections` tool per server takes a MongoDB-style pipeline, compiled to Arel/ActiveRecord. Values are always bound, never interpolated. *(M2–M4)*
- Expose Ruby methods as MCP **tools**, with typed parameters and JSON Schema generated for you. *(M5)*
- Several MCP servers in one app, each with its own collections, tools, instructions and authentication. *(M1, M3)*
- Authentication is one block that returns a context object (or `nil` → 401). The context reaches collections and tools. *(M1)*
- Every query runs read-only, with a statement timeout and a default and maximum limit. *(M6)*
- Multi-database (`connects_to`) and sharded (`routing_field`) collections. *(M6)*
- `ActiveSupport::Notifications` instrumentation for every query and tool call. *(M6)*
- Generators and rake tasks to scaffold, inspect and validate servers in CI. *(M7)*

---

## Quick start

### 1️⃣ Install

The gem isn't on RubyGems yet. Use it from GitHub:

```ruby
# Gemfile
gem "ror-mcp-server", github: "frutik/ror-mcp-server"
```

Once released *(M7)*: `bundle add ror-mcp-server`.

Requirements: Ruby ≥ 3.2, Rails ≥ 7.1.

---

### 2️⃣ Configure *(M1)*

Run the installer *(M7)*, or create the two files by hand:

```sh
bin/rails generate ror_mcp:install
```

```ruby
# config/initializers/ror_mcp.rb
RorMcp.configure do |c|
  c.default_server name: "myapp", instructions: "Data of MyApp. Call get_server_instructions first."

  c.authenticate do |request|              # return a context, or nil for 401
    key = ApiKey.check_token(request.authorization.to_s.delete_prefix("Bearer "))
    key && { user: key.user, api_key: key }
  end
end
```

```ruby
# config/routes.rb
mount RorMcp::Engine, at: "/mcp"           # serves the default server
```

The MCP endpoint is now `/mcp`.

---

### 3️⃣ Publish models *(M2)*

Create a collection in `app/mcp/`. Files there are loaded at boot.

```ruby
# app/mcp/order_collection.rb
class OrderCollection < RorMcp::Collection
  model  Order
  fields :id, :number, :status, :total, :customer, :placed_at
  instructions "One row per order. Latest = highest id."

  def scope(context)                       # = django-mcp-server's get_queryset
    Order.where(account: context[:user].account)
  end
end

class CustomerCollection < RorMcp::Collection
  model  Customer
  fields :id, :name, :country
end
```

`fields` is required. Use `fields :all` to publish every column, but see
[Description size](#description-size) first. `customer` is a `belongs_to`, and
because `Customer` is also published on the same server, clients can join to it with `$lookup`.

---

### 4️⃣ Publish tools *(M5)*

```ruby
# app/mcp/my_ai_tools.rb
class MyAiTools < RorMcp::Toolset
  tool :add, description: "A service to add two numbers together" do
    param :a, :integer, required: true
    param :b, :integer, required: true
  end

  def add(a:, b:)
    a + b
  end

  tool :send_email, writes: true, description: "A tool to send emails" do
    param :to_email, :string, required: true
    param :subject,  :string, required: true
    param :body,     :string, required: true
  end

  def send_email(to_email:, subject:, body:)
    ApplicationMailer.with(to: to_email, subject: subject, body: body).plain.deliver_now
    "sent"
  end
end
```

Ruby has no type hints, so parameters are declared with `param` instead of being
inferred as django-mcp-server does. Only declared methods become tools.

---

## Verify your setup

### Inspect what a server publishes *(M7)*

The counterpart of django-mcp-server's `manage.py mcp_inspect`:

```sh
bin/rails "ror_mcp:describe[default]"   # instructions, tools, and the size of each tool description
bin/rails ror_mcp:check                  # boot validations for CI: fields exist, references resolve, budget holds
```

### Talk to the endpoint with curl *(M1)*

```sh
curl -si http://localhost:3000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

The response is plain JSON (never an SSE stream) with an `Mcp-Session-Id` header. Send
that header with every later request.

---

## Use with an MCP client

**IMPORTANT** For non-public data, always configure [authentication](#authentication).

### MCP Python SDK

```python
from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession


async def main():
    async with streamablehttp_client("http://localhost:3000/mcp") as (read_stream, write_stream, _):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            result = await session.call_tool("query_data_collections", {
                "collection": "order",
                "search_pipeline": [{"$sort": {"id": -1}}, {"$limit": 5}],
            })
            print(result)

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
```

### Claude Code

```sh
claude mcp add --transport http myapp http://localhost:3000/mcp --header "Authorization: Bearer <token>"
```

### MCP Inspector

```sh
npx @modelcontextprotocol/inspector
```

Choose transport **Streamable HTTP**, enter `http://localhost:3000/mcp` and add your
`Authorization` header.

### Clients that only speak stdio

Only the Streamable HTTP transport is planned (django-mcp-server's `stdio_server`
command is not in the v1 plan), so stdio-only clients need an HTTP bridge.

---

## Querying collections

### The tool

Each server with collections gets one tool:

```
query_data_collections(collection: string, search_pipeline: object[] = [])
```

Its description holds a fixed preamble, the pipeline syntax below, and the `$jsonSchema`
of every collection on that server. Clients read the schemas from there. Tool name,
parameter names and description layout are the same as django-mcp-server's.

Collection names are the lowercase model name (`order`, `lineitem`), or whatever you
set with `collection_name`.

### Supported stages

| Stage | What it does |
|---|---|
| `$match` | Filters. Literal values mean equality. Operators: `$eq $ne $gt $gte $lt $lte $in $nin $regex`, logical `$and $or $nor`, `null` → `IS NULL`, and any operator enabled with `extra_filters`. Use `_id` for the primary key. |
| `$match: {$text: {$search: "…"}}` | Full-text search: every word must match at least one search field (case-insensitive). |
| `$search: {text: {query, path?}}` | Same search, optionally limited to some search fields. |
| `$lookup` | Joins a `belongs_to` target: `{from, localField, foreignField: "_id", as}`. Later stages use `as.field`. |
| `$sort` | `{field: 1}` ascending, `{field: -1}` descending. |
| `$skip` / `$limit` | Pagination. |
| `$project` | Picks output fields: `{field: 1}`, renames with `{"key": "$field"}` or `{"key": "$alias.field"}`. Dotted keys produce nested objects. |
| `$group` | Must be the last stage, and no `$project` may come before it. `_id` is `null`, `"$field"` or `{key: "$field", …}`. Accumulators: `$sum $avg $min $max $count`. |

Anything else (`$unwind`, `$addFields`, `$set`, …) is rejected with an error.

### Examples

These are real answers from the reference app (`spec/parity/expected/django`). The
Rails app must return the same bytes.

Join and project:

```json
[{"$lookup": {"from": "customer", "localField": "customer", "foreignField": "_id", "as": "c"}},
 {"$sort": {"id": 1}}, {"$limit": 4},
 {"$project": {"number": 1, "customer_name": "$c.name", "customer_country": "$c.country"}}]
```
```json
[{"number":"ORD-1001","customer_name":"Bram Peeters","customer_country":"BE"},
 {"number":"ORD-1002","customer_name":"Bram Peeters","customer_country":"BE"},
 {"number":"ORD-1003","customer_name":"Anna de Vries","customer_country":"NL"},
 {"number":"ORD-1004","customer_name":"Clara Müller","customer_country":"DE"}]
```

Aggregate:

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

### Output

Rows come back as one JSON text content. The primary key is `id` (or the model's own
primary key), foreign keys appear as `<name>_id`, decimals are numbers, and datetimes are
ISO 8601 in UTC. See [Output formats](#output-formats-and-embedded-resources) for CSV and
embedded resources.

### Pipeline semantics: `:parity` vs `:fixed` *(M6)*

django-mcp-server has behaviours that surprise clients and sometimes leak data.
`config.pipeline_semantics` picks between reproducing them exactly (`:parity`, useful when
migrating) and correcting them (`:fixed`, the default for new apps):

| django-mcp-server behaviour | `:parity` | `:fixed` |
|---|---|---|
| No `$project` returns **all** columns, including ones outside `fields` | reproduced | only `fields` + computed |
| `alias.field` after `$lookup` reaches any column of the joined model | reproduced | only the target collection's `fields` |
| The joined collection's `scope` is ignored | reproduced | applied as a join condition |
| `$lookup.from` isn't checked against the actual association | accepted | rejected with an explanation |
| `localField` names containing `_id` mid-word (`billing_identity`) break | reproduced | resolved by reflection |
| `$sort` with any value other than `1` sorts descending | reproduced | only `1` / `-1` |
| `$skip` is applied after `$limit`, whatever the order | reproduced | stages applied in order |
| `$project: {field: 0}` is ignored | reproduced | exclusion supported |
| No default or maximum `$limit` | reproduced | `default_limit` / `max_limit` |

`$sum: 1` counts rows with `COUNT(*)` in both modes, so models whose primary key isn't
`id` work. The read-only envelope applies in both modes.

---

## Collections reference

*(M2–M6)*

```ruby
class Sales::OrderCollection < RorMcp::Collection
  server :sales                             # default: the default server
  model  Order
  collection_name "order"                   # default: model_name.singular
  fields :id, :number, :status, :total_cents, :currency, :customer, :placed_at   # required (or :all)
  exclude_fields :internal_notes            # with fields :all
  search_fields :number                     # default: string/text columns within fields
  extra_filters :icontains, :startswith     # extra $match operators clients may use
  max_limit 500
  output_format :json                       # :json | :csv | :jsonl
  output_as_resource false                  # true → result attached as an embedded resource

  computed :line_count, :integer,
           sql: "(SELECT count(*) FROM line_items WHERE line_items.order_id = orders.id)",
           doc: "number of line items in the order"

  reference :customer, to: "customer"       # explicit, when reflection can't decide

  instructions <<~TXT
    One row per order. "status": pending, paid, shipped, cancelled.
    "customer" references the customer collection. Latest = highest id.
  TXT

  description "One row per order placed by a customer."    # schema description (Django: model docstring)
  describe :total, "Order total in cents"                  # field description (Django: help_text)
  choice_labels :currency, "EUR" => "Euro", "USD" => "US dollar"   # enum labels (Django: choices)

  def scope(context)                        # row-level filtering; context comes from authenticate
    Order.all
  end
end
```

| Option | Meaning |
|---|---|
| `server` | Which server publishes the collection. |
| `model` | The ActiveRecord model. |
| `collection_name` | Name clients use. Two collections can't share a name on one server (boot error). |
| `fields` | Published columns and associations. Required, so wide models don't bloat the tool description by accident. |
| `exclude_fields` | Columns to drop from `fields :all`. |
| `search_fields` | Columns used by `$text` / `$search`. |
| `extra_filters` | Extra `$match` operators, as in django-mcp-server (`{"name": {"$icontains": "x"}}`). |
| `computed` | A SQL/Arel expression published as a field. It appears in the schema, can be filtered, sorted and grouped, and is reachable through `$lookup`. |
| `reference` | Declares where an association points when it can't be inferred (STI, polymorphic, custom `class_name`). |
| `max_limit` | Upper bound on `$limit` for this collection. |
| `instructions` | Extra text appended to the collection's schema in the tool description. |
| `description` | The schema's top-level description. Default: `Model(field, …)`, like Django's auto docstring. |
| `describe` | A field's description. Default: the column comment, where the database has comments. |
| `choice_labels` | Labels for an enum's values. Default: the humanized enum key. |
| `output_format` / `output_as_resource` | See [Output formats](#output-formats-and-embedded-resources). |
| `connects_to` / `routing_field` | See [Multiple databases and sharding](#multiple-databases-and-sharding). |
| `abstract!` | Marks a shared base class, which is never published itself. |
| `scope(context)` | The relation queries start from (django-mcp-server's `get_queryset`). |

The schema comes from the model: column types → `bsonType`, `belongs_to` → `objectId` +
`ref`, `enum` → `enum`, `null: false` → `required` (except auto-increment keys and string
columns defaulting to `""`), and column comments or `describe` → descriptions. The schema
is printed in the same Python-`repr` form django-mcp-server uses, so descriptions match
byte for byte.

---

## Tools reference

*(M5)*

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

- A new toolset instance handles each call, with `context` (from `authenticate`) and `request` available.
- The return value becomes text content: strings as-is, other values as JSON.
- An exception becomes an MCP tool error (`isError: true`) whose text describes the failure, as in django-mcp-server.
- Tools run read-only unless declared `writes: true`.
- Parameter types: `:string`, `:integer`, `:number`, `:boolean`, `:object`, and arrays as `[:type]`.

---

## Advanced topics

### Multiple servers (secondary endpoints)

*(M1, M3)* Declare more servers and mount each one where you like:

```ruby
# config/initializers/ror_mcp.rb
RorMcp.configure do |c|
  c.default_server name: "myapp-catalog", instructions: "…"
  c.server :sales,   name: "myapp-sales",   instructions: "…"
  c.server :support, name: "myapp-support", instructions: "…", stateless: true
end
```

```ruby
# config/routes.rb
scope "/mcp" do
  mount RorMcp.endpoint(:default), at: "catalog"
  mount RorMcp.endpoint(:sales),   at: "sales"
  mount RorMcp.endpoint(:support), at: "support"
end
```

Collections and toolsets pick their server with `server :sales`. The same model can be
published on several servers. Collections are registered by `[server, collection_name]`,
not by class name, so classes in different modules never clash.

### Authentication

*(M1)* `authenticate` gets the `ActionDispatch::Request` and returns a context object, or
`nil` to answer `401` with `WWW-Authenticate: Bearer`. The context is passed to
collection `scope`s and to tools.

```ruby
RorMcp.configure do |c|
  c.authenticate do |request|                         # applies to every server…
    token = request.authorization.to_s.delete_prefix("Bearer ")
    (user = User.find_by_api_token(token)) && { user: user }
  end

  c.server :partners, name: "partners",               # …unless a server sets its own
           authenticate: ->(request) { Partner.authenticate(request) }
end
```

The endpoint is a plain Rack app, so there are no cookies and no CSRF checks. Token
clients don't need the workaround that DRF's `SessionAuthentication` forces on
django-mcp-server. OAuth isn't part of v1.

**Host checks:** the endpoint relies on Rails' `config.hosts` (HostAuthorization). Make
sure the host your clients use is allowed.

### Session management

*(M1)* Servers are stateful by default, with the same rules as django-mcp-server:

- `initialize` without a session gets a new `Mcp-Session-Id`.
- Any other request without one is answered `400`. An unknown or expired id gets `404`.
- `DELETE` ends the session.

```ruby
c.session_store = :memory   # per process; fine for one Puma worker / development
c.session_store = :cache    # Rails.cache; needs a shared cache (Redis, Memcached) with several processes
c.session_store = MyStore.new  # anything with create / exists? / delete
```

`stateless: true` on a server skips sessions entirely: every request stands alone. MCP
responses are always plain JSON, never SSE streams.

### Output formats and embedded resources

*(M5)* Per collection:

```ruby
output_format :csv           # :json (default) | :csv | :jsonl
output_as_resource true      # reply "Results attached" + the data as an embedded resource
```

Custom formats can be registered as renderers. CSV output flattens nested values into
dotted columns, as DRF's CSV renderer does.

### Serializing tool output

*(M5)* The counterpart of `drf_serialize_output`:

```ruby
tool :latest_order, description: "The most recent order",
                    serialize_with: OrderSerializer   # ActiveModel::Serializer, Blueprinter, or any #call / #as_json

def latest_order
  Order.order(id: :desc).first
end
```

### Computed fields

*(M4)* Values that live in SQL rather than in a column. They appear in the schema
(marked as computed) and work in every stage, including from another collection through
`$lookup`:

```ruby
computed :line_count, :integer,
         sql: "(SELECT count(*) FROM line_items WHERE line_items.order_id = orders.id)",
         doc: "number of line items in the order"
```

### Safety: read-only queries, timeouts, limits

*(M6)* Every collection query runs inside:

```ruby
connected_to(role: read_role) { while_preventing_writes { transaction {
  # SET TRANSACTION READ ONLY; SET LOCAL statement_timeout …
} } }
```

```ruby
c.read_role         = :reading        # route queries to a replica
c.statement_timeout = 15.seconds
c.default_limit     = 100             # applied when the pipeline has no $limit
```

For defence in depth, also give the MCP database role read-only grants.

### Multiple databases and sharding

*(M6)*

```ruby
class Billing::InvoiceCollection < RorMcp::Collection
  model Invoice
  connects_to :billing                # a collection in another database
  fields :all
end

class Analytics::EventCollection < RorMcp::Collection
  model Event
  fields :id, :name, :region, :occurred_at
  routing_field :region, to: ->(value) { { shard: value.to_sym } }
end
```

A `$lookup` across databases is rejected at boot. A routing field must appear in `$match`
(`{"region": "eu"}`), and the query then runs under `connected_to(shard: :eu)`. Using it in
`$sort`, `$project`, `$group` or `$lookup` is rejected with an error that explains why.

### Description size

*(M6)* The `query_data_collections` description contains every collection's schema. If it
grows too long, some clients truncate it and silently lose collections, while the server
still connects as if nothing were wrong.

```ruby
c.description_budget = 25_000   # characters; warns or raises at boot when exceeded
```

`bin/rails ror_mcp:describe` prints each server's description size.

### Instrumentation

*(M6)* `ActiveSupport::Notifications` events:

| Event | Payload |
|---|---|
| `query.ror_mcp` | server, collection, pipeline, rows, duration, error |
| `tool.ror_mcp` | server, tool, duration, error |

```ruby
c.on_query { |event| Rails.logger.info(event.to_h.to_json) }
```

### Generators and rake tasks

*(M7)*

```sh
bin/rails g ror_mcp:install                                          # initializer, route, app/mcp/
bin/rails g ror_mcp:collection Sales::Order --server sales --fields id number status
bin/rails g ror_mcp:toolset Sales::CatalogSearch
bin/rails "ror_mcp:describe[sales]"
bin/rails ror_mcp:check
```

---

## Coming from django-mcp-server

| django-mcp-server | ror-mcp-server |
|---|---|
| `INSTALLED_APPS += ["mcp_server"]` + `path("", include("mcp_server.urls"))` | `gem "ror-mcp-server"` + `mount RorMcp::Engine, at: "/mcp"` |
| `<app>/mcp.py` autodiscovery | `app/mcp/**/*.rb`, loaded at boot |
| `DJANGO_MCP_GLOBAL_SERVER_CONFIG` | `c.default_server name:, instructions:, stateless:` |
| `DjangoMCP(name=…)` + `MCPServerStreamableHttpView.as_view(mcp_server=…)` | `c.server :name, …` + `mount RorMcp.endpoint(:name), at: …` |
| `DJANGO_MCP_AUTHENTICATION_CLASSES` | `c.authenticate { \|request\| … }` (global or per server) |
| `ModelQueryToolset` | `RorMcp::Collection` |
| `model`, `fields`, `exclude_fields`, `search_fields`, `extra_filters` | same names |
| `extra_instructions` | `instructions` |
| `get_queryset()` (with `self.request`) | `scope(context)` |
| `output_format`, `output_as_resource` | same names |
| `MCPToolset` (public methods + type hints) | `RorMcp::Toolset` (`tool` + `param` declarations) |
| `@drf_serialize_output(S)` | `serialize_with: S` |
| `DJANGO_MCP_OUTPUT_RENDERER_CLASSES` | `output_format` + registered renderers |
| `DJANGO_MCP_GET_SERVER_INSTRUCTIONS_TOOL` | `c.instructions_tool` |
| `manage.py mcp_inspect` | `bin/rails ror_mcp:describe` |
| `drf_publish_*_mcp_tool` (DRF views as tools) | not in v1 (planned: `publish_action`) |
| `manage.py stdio_server` | not in v1 |
| `@mcp_server.tool()` low-level FastMCP tools | not in v1 |

Unchanged for clients: the tools `query_data_collections` and `get_server_instructions`,
their parameters, the description layout, the pipeline syntax, and the shape of results.
Under `:parity` semantics, results are byte-identical.

---

## Development

```sh
git clone --recurse-submodules git@github.com:frutik/ror-mcp-server.git
bundle install
bundle exec rspec
```

The repository contains:

| Path | What |
|---|---|
| `lib/` | The gem. |
| `django-mcp-server/` | Submodule: the library being ported (reference source). |
| `spec/parity/django_app/` | Reference Django app: a shop schema published with django-mcp-server (two servers, tools, CSV, embedded resources, bearer auth). |
| `spec/parity/expected/django/` | Its recorded answers: HTTP/session behaviour, `tools/list`, 107 `tools/call` cases. |
| `spec/parity/client/` | `mcp_parity.py` (record / check any endpoint), `sdk_smoke.py` (official SDK client), `compare_dbs.py`. |
| `spec/dummy/` | Rails app with the same schema and data, publishing the same servers through this gem. |
| `spike/transport/` | M0 spike: the `mcp` gem's transport behind Django-style session rules. |
| `PLAN.md` | Design, milestones, decisions and verified assumptions. |

Run the parity check against the Rails app:

```sh
python -m venv .venv && .venv/bin/pip install -r spec/parity/requirements.txt
spec/parity/bin/rails-server &                                                       # :3765
.venv/bin/python spec/parity/client/mcp_parity.py check --base-url http://127.0.0.1:3765
```

[`spec/parity/README.md`](spec/parity/README.md) explains the suite, how to re-record the
golden output, and the django-mcp-server behaviours it pins.

---

## License

MIT, see [LICENSE](LICENSE). Parts are derived from
[django-mcp-server](https://github.com/omarbenhamid/django-mcp-server) by Omar BENHAMID,
also MIT-licensed. Many thanks to its author and contributors.
