# ror-mcp-server — Project Plan

> A standalone Ruby gem that does for Rails what
> [`django-mcp-server`](https://github.com/omarbenhamid/django-mcp-server)
> does for Django: mount MCP servers inside a Rails app, publish ActiveRecord
> models as queryable *collections* with a MongoDB-style aggregation pipeline,
> and publish plain Ruby methods as MCP tools.

---

## 1. Goal and scope

**Deliverable:** gem `ror-mcp-server` (require `ror_mcp_server`, namespace
`RorMcp`), published to RubyGems, with a Rails engine/railtie, generators,
docs and a CI-tested dummy app.

**Success test:** whatever a Django project can publish with django-mcp-server
(several mounted servers, model collections with field whitelists, join targets,
custom tools, bearer auth), a Rails app can publish with ror-mcp-server in
about the same amount of code. The same pipelines then return the same results
against the same data (§7 parity suite).

**Out of scope for v1:** OAuth, MCP resources/prompts, server→client
notifications, SSE streaming, `$unwind`/`$addFields`, has_many `$lookup`,
wrapping controllers as tools.

---

## 1A. What django-mcp-server does, exactly

Read from the **0.5.7** source (`mcp_server/`: `apps.py`, `djangomcp.py` 785
lines, `query_tool.py` 718 lines, `views.py`, `urls.py`; ≈1.6k lines in
total). It's a thin layer over the official Python MCP SDK (`FastMCP` +
`StreamableHTTPSessionManager`) and does six things.

### 1. Boot and registration (`apps.py`, `djangomcp.init`, `query_tool.init`)

1. On `AppConfig.ready()`, `autodiscover_modules('mcp')` imports `<app>/mcp.py`
   for every installed app.
2. Two metaclasses collect subclasses into global dicts keyed by **class
   name**: `ToolsetMeta.registry` (`MCPToolset`) and
   `ModelQueryToolsetMeta.registry` (`ModelQueryToolset`). Every subclass
   registers, including intermediate "base" classes.
3. Classes without `mcp_server` get the global server (built at import time
   from `DJANGO_MCP_GLOBAL_SERVER_CONFIG`).
4. Each `MCPToolset` is instantiated once and its public methods are added to
   its server's FastMCP tool manager.
5. Per server, one `QueryTool` is built from all `ModelQueryToolset`s on it,
   keyed by **lowercase model name**, and registered as the single tool
   `query_data_collections`. Its description is rendered **once, at boot**.

### 2. Servers and transport (`DjangoMCP`, `MCPServerStreamableHttpView`)

- `DjangoMCP(name, instructions, stateless=False)` subclasses `FastMCP` and
  adds a `get_server_instructions` tool ("Always call first.") unless
  `DJANGO_MCP_GET_SERVER_INSTRUCTIONS_TOOL = False`.
- The view is a DRF `APIView` (CSRF-exempt). GET and POST go to
  `handle_django_request`, and DELETE flushes the session.
- **Sessions are Django sessions, not SDK sessions.** In stateful mode:
  - With an `Mcp-Session-Id` header, the session must exist (404 otherwise).
  - Without the header, a session is created only for an `initialize` request
    (400 "Session required for stateful server" otherwise).
  - After each request the session is saved and its key returned in
    `Mcp-Session-Id`.

  The session stores nothing MCP-specific; it's only an existence check.
- The SDK side always runs **stateless and with `json_response=True`**. Each
  HTTP request builds a fresh `StreamableHTTPSessionManager`, translates the
  Django request into an ASGI scope, and runs it to completion. The whole
  body is buffered, so the response is **plain JSON, never SSE**.
- Auth isn't the library's job. `mcp_server.urls` mounts the view at
  `DJANGO_MCP_ENDPOINT` (default `mcp`) with
  `DJANGO_MCP_AUTHENTICATION_CLASSES` and `IsAuthenticated` if set. The Django
  request is put in a contextvar so tools can read `request.user`.

### 3. Custom tools (`MCPToolset`)

- Every public method (not starting with `_`) becomes a tool. Name, parameter
  JSON schema and description come from FastMCP's introspection of type hints
  and the docstring.
- For **every call**, a new toolset instance is created with `context` (the
  MCP context) and `request` (the Django request), then the method runs via
  `sync_to_async`.
- Return value: a `QuerySet` becomes a list. With `@drf_serialize_output(S)`
  the result goes through `S(ret).data`. Then FastMCP's normal result
  conversion applies.
- Exceptions are logged and re-raised, and FastMCP turns them into tool errors.

### 4. DRF views as tools (`register_drf_*_tool`, `drf_publish_*_mcp_tool`)

Wraps DRF Create/List/Update/Destroy views as tools (`body`, `id` params; body
schema from the serializer). The view runs on a fake request that carries the
original user and session.

### 5. Model collections (`ModelQueryToolset`, `QueryTool`, `generate_json_schema`)

- Attributes: `model`, `fields`, `exclude_fields`, `search_fields`,
  `extra_filters`, `extra_instructions`, `output_format` (`json` by default;
  other DRF renderers via `DJANGO_MCP_OUTPUT_RENDERER_CLASSES`),
  `output_as_resource`, `mcp_server`. Hook: `get_queryset()`, with
  `self.request` / `self.context`.
- **Field exclusion**: any relation whose `related_model` (exact class) isn't
  published on the same server is dropped from the schema, plus
  `exclude_fields`. Cached in `_effective_*` class attributes.
- **Text search fields**: `search_fields`, otherwise every concrete
  Char/TextField within `fields`.
- **Description of `query_data_collections`** = a fixed preamble +
  `PIPELINE_DSL_SPEC` + for each collection: a MongoDB-style `$jsonSchema`
  (Django field → `bsonType`, FK → `objectId` + `ref: <ModelName>`, `choices`
  → `enum` + labels, `help_text` → description, non-null non-blank →
  `required`) + its text-search fields + `extra_instructions`.
- **Tool signature**: `query_data_collections(collection: str,
  search_pipeline: list[dict] = [])`. An unknown collection raises with the
  list of valid names.
- **`fields` and `exclude_fields` only shape the schema (the description).**
  Queries never check them: see "(none)" and `$lookup` in the next table.

### 6. The pipeline → QuerySet compiler (`apply_json_mango_query`)

Semantics that the port has to reproduce exactly. Several of them are surprising:

| Stage | Exact behaviour in 0.5.7 |
|---|---|
| `$lookup` | **Doesn't join anything by itself.** Processed in a first pass, whatever its position. It only records an alias: `as` → `prefix = localField.replace("_id", "")`. Validation: `from` must be a published model on the server (**it isn't checked against the FK's target**). `localField` must be a many-to-one field (`get_field` also accepts the attname, e.g. `author_id`), and `foreignField` must be `_id`/`pk`/the PK name. Later `alias.field` references become Django `prefix__field` paths, and the ORM adds the JOIN when the path is used. Any field of the related model is reachable this way, **not only the target collection's `fields`**, and the target collection's `get_queryset()` (row filtering, annotations) is **not applied**. |
| `$match` | Builds a `Q`. `$and` / `$or` / `$nor`. Per field: a literal → equality; `{$op: v}` with `$eq` (`null` → `isnull`), `$ne` / `$nin` (negated `Q`), `$gt $gte $lt $lte $in`, `$regex` → `__regex`, any name in `extra_filters` → `__<op>`. Anything else raises. `_id` → `pk`. `$text: {$search}` inside `$match` → per-word AND of OR'ed `icontains` over the search fields. |
| `$search` | `{text: {query, path?}}` → same `icontains` search; `path` must be a subset of the search fields. |
| `$sort` | `order_by`; a direction of `1` is ascending, **any other value is descending**. |
| `$limit` | Slices the queryset immediately (`qs[:n]`). |
| `$skip` | Stored and applied **at the end** (`qs[skip:]`), so `$limit` then `$skip` returns `n - skip` rows. Not MongoDB semantics. |
| `$project` | Not allowed if a `$group` follows. A truthy value includes the field and a `"$path"` string maps an output key to a (lookup) path. **`0`/`false` is ignored, not an exclusion.** Dotted output keys become nested objects. Output is `values(*fields)` remapped. |
| `$group` | Must be the last stage. `_id: null` → `aggregate()` (one row); `"$f"` → `values(f).annotate()`; `{k: "$f"}` → multiple keys, output under `_id.k`. Accumulators: `$sum` (`1` → **`Count("id")`**, or a `"$f"` → `Sum`), `$avg`, `$min`, `$max`, `$count` (`1` → `Count("id")`, `"$f"` → `Count(f)`). |
| (none) | No `$project` → `queryset.values()`: **all concrete columns of the base model, including ones not in `fields`**, plus `get_queryset()` annotations, with FKs as `<name>_id`. Lookup data appears only through `$project`. |
| Limits | **No default limit and no maximum.** No statement timeout, and no read-only enforcement other than the absence of write paths. |
| Output | DRF renderer → one `TextContent` (or an embedded resource if `output_as_resource`). The PK comes out as `id`; `_id` exists only inside pipelines. An empty result returns `[]` unrendered. |

---

## 1B. What we build, exactly

One gem, `ror-mcp-server`. These are its components, mapped to the parts of
§1A they replace. Size estimates are for planning only.

| # | Component | Replaces (§1A) | Responsibility | Est. LOC |
|---|---|---|---|---|
| C1 | `RorMcp::Configuration` + `RorMcp.configure` | settings, `global_mcp_server` | Default + named servers, auth block, session store, limits, timeouts, budget, renderers, instrumentation hook | 120 |
| C2 | `RorMcp::Engine` (railtie) | `apps.py` autodiscovery, `init()` | Eager-load `app/mcp/**`, validate the registry, build servers and their tool lists **after boot**, re-run on code reload in development | 80 |
| C3 | `RorMcp::Registry` | the two metaclass registries | Collections keyed by `[server, collection_name]`, toolsets by `[server, tool_name]`; duplicate → boot error; abstract classes skipped | 80 |
| C4 | `RorMcp::Server` | `DjangoMCP` | Wraps `MCP::Server` from the `mcp` gem: name, instructions, tools; adds `get_server_instructions` | 80 |
| C5 | `RorMcp::Endpoint` (Rack app) + `SessionStore::{Null,Memory,Cache}` | `MCPServerStreamableHttpView`, Django sessions, ASGI bridge | Auth block → 401; `Mcp-Session-Id` rules identical to §1A.2 (404 / 400 / issue on `initialize`, DELETE flushes); calls the SDK; **JSON responses only, no SSE** (same as Django) | 180 |
| C6 | `RorMcp::Toolset` + `tool`/`param` DSL | `MCPToolset`, `drf_serialize_output` | Declared tools → JSON schema; new instance per call with `context` + `request`; return value → JSON text; `serialize_with:`; errors → `isError`; `writes: true` flag | 200 |
| C7 | `RorMcp::Collection` DSL | `ModelQueryToolset` | `server`, `model`, `collection_name`, `fields` (required), `exclude_fields`, `search_fields`, `extra_filters`, `instructions`, `scope(context)`, `computed`, `reference`, `max_limit`, `output_format`, `output_as_resource`, `connects_to`, `routing_field`, `abstract!` | 220 |
| C8 | `RorMcp::Schema` | `generate_json_schema`, field exclusion | Same `$jsonSchema` shape: `columns_hash` → `bsonType`, `belongs_to` → `objectId` + `ref` (by collection on same server), `defined_enums` → `enum`, column comments → description, `null: false` → `required`, computed fields included and marked | 150 |
| C9 | `RorMcp::Tools::QueryTool` | `QueryTool` | Tool `query_data_collections(collection, search_pipeline)` with the **same preamble, DSL spec text and per-collection layout**; unknown-collection error lists the names | 100 |
| C10 | `RorMcp::Pipeline::Compiler` (+ `Match`, `Lookup`, `Project`, `Group`, `Errors`) | `apply_json_mango_query` | Every row of §1A.6, reproduced on Arel/ActiveRecord, with the deliberate deviations listed below | 600 |
| C11 | `RorMcp::Executor` | `_QueryExecutor` | Resolves collection → `scope(context)` → compile → run inside the safety envelope (§5) → render → MCP content / embedded resource | 100 |
| C12 | `RorMcp::Renderers::{Json,Csv,Jsonl}` | DRF renderers | Formats; JSON encoding matches DRF `JSONRenderer` for dates/decimals/UUIDs | 80 |
| C13 | Generators `install`, `collection`, `toolset` | — | Scaffolding | 150 |
| C14 | Rake `ror_mcp:describe`, `ror_mcp:check` | — | Print per-server description + size; CI validation | 60 |
| C15 | `RorMcp::Instrumentation` | — | `ActiveSupport::Notifications` events `query.ror_mcp`, `tool.ror_mcp` (server, collection/tool, pipeline, rows, ms, error) | 40 |
| C16 | Test suite + dummy app + Django reference app + parity harness | — | §7 | — |
| C17 | README, usage guide (pitfalls, instruction-writing, client setup), CHANGELOG | — | Docs | — |

**Not built in v1:** the DRF-view wrapping of §1A.4 (v2 `publish_action`),
SSE streaming, OAuth, MCP resources and prompts.

### Parity vs deliberate deviations in C10

C10 has two modes. **Parity mode** reproduces every behaviour in §1A.6, so the
parity suite can diff output byte for byte. **Fixed mode**
(`config.pipeline_semantics = :fixed`) corrects the behaviours that are bugs
or hazards. Fixed mode is the default for new apps and documented as such.

| 0.5.7 behaviour | `:parity` | `:fixed` |
|---|---|---|
| `$lookup.from` not checked against the FK target | accept | reject with "localField X points at collection Y" |
| `localField.replace("_id", "")` mangles names containing `_id` mid-word | reproduce | resolve via `reflect_on_association`; accept the association name (`author`) and the FK column (`author_id`) |
| `alias.field` reaches any column of the related model | reproduce | only the target collection's `fields` + computed |
| Target collection's `get_queryset()` ignored on `$lookup` | reproduce | target `scope(context)` applied as a join condition (row filtering holds across joins) |
| No `$project` → **all** columns, including non-whitelisted ones | reproduce (with a boot warning) | only `fields` + computed |
| `$sort` with any non-`1` value → descending | reproduce | only `1` / `-1`; anything else raises |
| `$skip` applied after `$limit` | reproduce | stages applied in order (MongoDB semantics) |
| `$project: {f: 0}` ignored | reproduce | exclusion projection supported |
| `$sum: 1` / `$count: 1` → `Count("id")` | `COUNT(*)` (same result whenever `id` exists; fixes non-`id` PKs) | same |
| No default/maximum limit | `default_limit: nil` | `default_limit` + `max_limit` enforced |
| Empty result → raw `[]` | reproduce | rendered `[]` (one text content) |

The safety envelope (read-only transaction, statement timeout) applies in
both modes. It doesn't change results, only stops unsafe ones.

---

## 2. Feature parity map (django-mcp-server 0.5.7 → ror-mcp-server)

| django-mcp-server | What it does | ror-mcp-server equivalent |
|---|---|---|
| `DjangoMCP(name, instructions, stateless)` (wraps FastMCP) | A server instance | `RorMcp::Server.new(name:, instructions:, stateless:)`, built on the official `mcp` gem's `MCP::Server` |
| `DJANGO_MCP_GLOBAL_SERVER_CONFIG` + `global_mcp_server` | Default server from settings | `RorMcp.configure { \|c\| c.default_server name:, instructions: }` |
| `MCPServerStreamableHttpView.as_view(mcp_server=…)` | Streamable HTTP endpoint (DRF view) | `RorMcp::Endpoint.new(server)`, a Rack app; routes: `mount RorMcp.endpoint(:sales), at: "/mcp/sales"` |
| `mcp_server.urls` + `DJANGO_MCP_ENDPOINT` | Default route | `mount RorMcp::Engine, at: "/mcp"` serves the default server |
| `DJANGO_MCP_AUTHENTICATION_CLASSES` | DRF authenticators | `config.authenticate { \|request\| … }` returns a context object or nil (→ 401 + `WWW-Authenticate: Bearer`) |
| Django-session-backed MCP sessions | `Mcp-Session-Id` storage | Pluggable `config.session_store` (`:memory`, `:cache` = `Rails.cache`, custom); `stateless: true` skips sessions |
| `apps.py` autodiscovery of `<app>/mcp.py` | Registration | Zeitwerk: eager-load `app/mcp/**/*.rb` in the railtie (dev and prod alike) |
| `ModelQueryToolset` (`model`, `fields`, `exclude_fields`, `search_fields`, `extra_filters`, `extra_instructions`, `get_queryset`, `output_format`, `output_as_resource`) | Collection publishing | `RorMcp::Collection` DSL with the same concepts (§4.2) |
| `QueryTool` → `query_data_collections` | One query tool per server, all schemas in its description | Same tool name and description shape, so clients and prompts transfer as-is |
| `get_server_instructions` tool (`DJANGO_MCP_GET_SERVER_INSTRUCTIONS_TOOL`) | Instructions on demand | Same, toggle `config.instructions_tool` |
| `generate_json_schema` | Model → `$jsonSchema` | `RorMcp::Schema.for(collection)` from `columns_hash`, `defined_enums`, column comments, associations |
| `apply_json_mango_query` + `PIPELINE_DSL_SPEC` | Pipeline → QuerySet | `RorMcp::Pipeline::Compiler` → `ActiveRecord::Relation` / Arel (§5) |
| `MCPToolset` (public methods → tools, from type hints + docstring) | Custom tools | `RorMcp::Toolset` with a `tool` DSL declaring params with types/descriptions (Ruby has no type hints) (§4.3) |
| `drf_publish_*_mcp_tool`, `register_drf_*_tool` | Expose DRF views as tools | v2: `publish_action` for a controller action / Jbuilder; not v1 |
| `drf_serialize_output` | Serialise tool output via a DRF serializer | `serialize_with:` option (ActiveModel::Serializer / Blueprinter / `as_json`) |
| `DJANGO_MCP_OUTPUT_RENDERER_CLASSES` (json, csv) | Output formats | `output_format :json \| :csv \| :jsonl`, pluggable renderers |

---

## 3. Improvements over django-mcp-server (designed in from day one)

Each row is a problem a django-mcp-server deployment hits in practice and has
to work around by hand. The gem should make the workaround unnecessary.

| Problem in practice | Root cause in the Django lib | Gem design |
|---|---|---|
| Two published models with the same class name in different apps: one silently disappears. Workaround: proxy models (plus migrations) to rename them | Collections keyed by bare `model_name` | Explicit `collection_name` (default `model_name.singular`); registry key `[server, name]`; **duplicates raise at boot** |
| Publishing one model on several servers needs distinct toolset class names, or one clobbers the other | Registry keyed by class name | Registry ignores class names; namespacing by module is enough |
| A shared base toolset gets published itself; cached `_effective_*` attributes leak to subclasses via the MRO | Metaclass registers every subclass | `abstract!` macro; only classes with `model` + `server` register; no class-level caches |
| An FK to a concrete model is silently dropped from the schema when only a proxy/subclass of it is published | Exact-class `related_model` check | References resolve by **collection on the same server** via `belongs_to` reflection (STI/subclass-aware), or explicit `reference :author, to: "user"`. A dropped field becomes a boot warning |
| A `localField` containing `_id` mid-word (`owner_id_cache`) breaks lookups | `replace("_id", "")` on the field path | Association resolved by reflection (§1B fixed mode) |
| `{"$sum": 1}` fails on any model whose PK isn't `id` | Hardcoded `Count("id")` | `COUNT(*)`; `_id` → `model.primary_key` (composite PKs supported, Rails 7.1+) |
| Computed values (annotations) are invisible to clients and unreachable via `$lookup` | Annotations live only in `get_queryset()`; the schema doesn't see them; lookups bypass the target queryset | `computed :name, :type, sql:/arel:, doc:`: in the schema, marked "computed, not a reference", and **reachable through `$lookup`** |
| One wide model (dozens of columns, JSON blobs) makes the tool description so long that clients truncate it, hiding every collection. The server still connects, so nothing looks wrong | No size awareness; `fields` optional | `fields` **required** (boot error without it, opt-out `fields :all`); `rake ror_mcp:describe` prints per-server description size; configurable `description_budget` warns/raises |
| The field whitelist doesn't actually restrict queries (§1A.6 "(none)", `$lookup`) | `fields` used only for the schema | Enforced at query time in fixed mode |
| Links between collections in different databases need hand-written `Case/When` annotations | No multi-DB concept | `connects_to:` per collection; cross-connection `$lookup` rejected at boot; `computed … resolver:` helper builds the CASE from a cached mapping |
| Rows split across per-tenant/per-region databases need a hand-rolled "routing" pseudo-field | No sharding concept | `routing_field :region, to: ->(v) { {shard: v.to_sym} }`; required in `$match`, runs under `connected_to(shard:)`, rejected in sort/project/group/lookup with an explanatory error |
| A token-authenticated client gets 403 "CSRF Failed" once the user is set, because DRF's `SessionAuthentication` enforces cookie CSRF. Workaround: a custom DRF authenticator | Endpoint is a DRF `APIView` | Pure Rack endpoint: no cookies, no CSRF, auth is one block |
| Read-only only by convention | Nothing enforces it | Every query runs in a read-only transaction (`while_preventing_writes` + DB-level `READ ONLY`), optional `role: :reading`, `SET LOCAL statement_timeout`, `max_limit` + default limit |
| Error messages are terse and misspelled ("reveiwe pipeline syntax") | Ad hoc | Errors are written for an LLM: name the bad stage/field, list valid options, suggest the fix |

---

## 4. Public API

The examples use a neutral sales domain (`Order`, `Customer`, `Product`).

### 4.1 Configuration and servers

```ruby
# config/initializers/ror_mcp.rb
RorMcp.configure do |c|
  c.default_server name: "myapp-catalog", instructions: "…"
  c.server :sales,   name: "myapp-sales",   instructions: "…"
  c.server :support, name: "myapp-support", instructions: "…", stateless: true

  c.authenticate do |request|              # → context or nil (401)
    key = ApiKey.check_token(request.authorization.to_s.delete_prefix("Bearer "))
    key && { user: key.user, api_key: key }
  end

  c.session_store       = :cache           # :memory | :cache | custom object
  c.read_role           = :reading         # optional replica
  c.statement_timeout   = 15.seconds
  c.default_limit       = 100
  c.description_budget  = 25_000           # chars; :warn or :raise
  c.pipeline_semantics  = :fixed           # or :parity (§1B)
  c.on_query { |event| Rails.logger.info(event.to_h.to_json) }   # instrumentation hook
end
```

```ruby
# config/routes.rb
scope "/mcp" do
  mount RorMcp.endpoint(:default), at: "catalog"
  mount RorMcp.endpoint(:sales),   at: "sales"
end
```

### 4.2 Collections

```ruby
# app/mcp/sales/order_collection.rb
module Sales
  class OrderCollection < RorMcp::Collection
    server :sales
    model  Order
    fields :id, :number, :status, :total_cents, :currency, :customer, :placed_at
    search_fields :number
    extra_filters :icontains, :startswith    # extended operators, as in django-mcp-server
    max_limit 500

    computed :line_count, :integer,
             sql: "(SELECT count(*) FROM line_items WHERE line_items.order_id = orders.id)",
             doc: "number of line items in the order"

    instructions <<~TXT
      One row per order. "status": pending, paid, shipped, cancelled.
      "customer" references the customer collection. Latest = highest id.
    TXT

    def scope(context)                       # = get_queryset; context from authenticate
      Order.all
    end
  end

  class CustomerCollection < RorMcp::Collection   # thin join target
    server :sales
    model  Customer
    fields :id, :name, :country
  end
end
```

Associations listed in `fields` (`customer`) become `ref` entries in the
schema when their target is published on the same server.

### 4.3 Custom tools

```ruby
# app/mcp/sales/catalog_search_tools.rb
module Sales
  class CatalogSearchTools < RorMcp::Toolset
    server :sales

    tool :search_products,
         description: "Full-text search over the product catalog …" do
      param :query,  :string,   required: true, desc: "search terms"
      param :brands, [:string]
      param :limit,  :integer,  default: 20
    end

    def search_products(query:, brands: nil, limit: 20)
      ProductSearch.call(query:, brands:, limit:)
    end                                       # return value → JSON text content

    # writes must be declared; they run outside the read-only envelope
    tool :flag_order, writes: true, description: "…" do
      param :order_id, :integer, required: true
      param :reason,   :string,  required: true
    end
  end
end
```

Inside a tool: `context` (from `authenticate`) and `request` are available.
Exceptions turn into MCP tool errors (`isError: true`).

---

## 5. Pipeline compiler (the core)

Same DSL subset and wording as django-mcp-server's `PIPELINE_DSL_SPEC`, so
existing prompts and client habits carry over. Exact source semantics are in
§1A.6; the table below is how each stage compiles in Rails.

| Stage | Compiles to | Notes |
|---|---|---|
| `$match` | Arel predicates; `$eq $ne $gt $gte $lt $lte $in $nin $regex $exists`, `$and $or $nor`; `null` → `IS NULL`; extended ops from `extra_filters` | Values always bound; adapter-specific regex (`~`/`~*` PG, `REGEXP` MySQL, function for SQLite). `$exists` is an addition (not in 0.5.7) |
| `$text` / `$search` | per-word `ILIKE`/`LIKE` across `search_fields`, AND across words | Optional `tsvector` adapter later |
| `$lookup` | Records alias `as` → `belongs_to` association path (no SQL by itself, as in Django); `alias.field` in later stages adds a LEFT JOIN with table alias `as` | Same server and same connection only; fixed mode limits fields to the target's whitelist and applies its `scope` |
| `$sort` / `$skip` / `$limit` | `order` / `offset` / `limit` | Parity: Django's ordering quirks; fixed: in-order, default + max limit |
| `$project` | `select … AS` incl. `"$alias.field"`; dotted keys → nested objects | |
| `$group` | final stage; `_id` null / `"$f"` / `{k: "$f"}`; `$sum $avg $min $max $count` | No `$project` before it (library rule kept) |

Output serialisation matches django-mcp-server: `QuerySet.values()`-shaped rows
as DRF's `JSONRenderer` would render them. PK as `id`, FKs as `<name>_id`,
DRF's date/decimal/UUID encoding, JSON columns passed through. The parity
suite pins this (§7).

Execution envelope (all configurable):

```ruby
connected_to(role: read_role) { while_preventing_writes { transaction {
  set_transaction_read_only; set_local_statement_timeout; relation.to_a
} } }
```

---

## 6. Gem layout

```
ror-mcp-server/
  lib/ror_mcp.rb
  lib/ror_mcp/
    version.rb
    configuration.rb
    engine.rb               # railtie: eager-load app/mcp, build servers after_initialize
    server.rb               # wraps MCP::Server; holds collections, toolsets
    endpoint.rb             # Rack app: auth → session → MCP transport
    session_store/{null,memory,cache}.rb
    registry.rb
    collection.rb           # DSL
    toolset.rb              # DSL
    schema.rb
    executor.rb
    pipeline/{compiler,match,lookup,group,project,errors}.rb
    renderers/{json,csv,jsonl}.rb
    tools/{query_tool,instructions_tool}.rb
    instrumentation.rb      # ActiveSupport::Notifications "query.ror_mcp", "tool.ror_mcp"
  lib/generators/ror_mcp/{install,collection,toolset}/
  lib/tasks/ror_mcp.rake    # describe, check
  spec/
    dummy/                  # Rails app: Customer, Order, LineItem, Product, Category (+ STI, non-id PK, JSON column)
    parity/django_app/      # minimal Django project with the same schema + django-mcp-server 0.5.7
    parity/pipelines/       # shared pipeline corpus + expected outputs
    pipeline/  schema/  endpoint/
  docs/  README.md  CHANGELOG.md  ror-mcp-server.gemspec
```

Dependencies: `rails >= 7.1` (composite PKs, `while_preventing_writes`,
`connected_to`), `mcp` (official SDK, pinned; verify transport API against its
source before M1), Ruby ≥ 3.2.

Generators:
- `rails g ror_mcp:install` writes the initializer, route and `app/mcp/`.
- `rails g ror_mcp:collection Sales::Order --server sales --fields id number status …`
- `rails g ror_mcp:toolset Sales::CatalogSearch`

Rake: `ror_mcp:describe[server]` prints instructions + description size per
server. `ror_mcp:check` runs boot validations in CI (fields exist, refs
resolve, budget).

---

## 7. Testing strategy

- **Unit**: compiler stage by stage, with SQL snapshot assertions.
- **Parity suite**: a minimal Django reference app (`spec/parity/django_app`)
  running django-mcp-server 0.5.7, and the Rails dummy app, share one schema
  and one fixture set. A corpus of ~50 pipelines covers every stage, operator
  and quirk in §1A.6. Each pipeline runs on both, and in `:parity` mode the
  JSON must be identical. This is the parity contract. The same corpus in
  `:fixed` mode has its own expected outputs.
- **Pitfall regression suite**: one spec per row of §3, written as the Django
  failure scenario and asserting the gem behaves correctly.
- **Endpoint**: initialize / tools/list / tools/call over Streamable HTTP, 401
  path, the §1A.2 session rules (404 / 400 / DELETE), stateless, multiple
  mounted servers.
- **Matrix**: Postgres (primary), MySQL, SQLite × Rails 7.1 / 7.2 / 8.x × Ruby 3.2–3.4.
- **Client smoke**: a CI job connects an MCP client to the dummy app and lists
  the tools (optional, nightly).

---

## 8. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | Repo, gemspec, CI matrix, dummy app, Django reference app, spike on `mcp` gem transport | Spike answers `initialize` from a Rack app; transport API confirmed |
| M1 | `Server`, `Endpoint`, auth hook, session stores, `get_server_instructions` | 401 without a key; `initialize` returns 200 + `Mcp-Session-Id`; an MCP client lists the tools |
| M2 | `Collection` DSL, registry, schema, `query_data_collections` with `$match $sort $skip $limit $project` | First parity pipelines pass |
| M3 | `$lookup`, references, thin join targets, multiple servers | §3 rows for name clashes, class-name registry, proxy/STI refs and `_id` mangling green |
| M4 | `$group`, `$text/$search`, `extra_filters`, computed fields (incl. via `$lookup`) | Full parity suite green |
| M5 | `Toolset` DSL, write tools, renderers (json/csv), `serialize_with` | A custom tool and a write tool work from an MCP client |
| M6 | Safety envelope, `connects_to`, `routing_field`, description budget, instrumentation, fixed mode | Multi-DB and sharded cases green; fixed-mode corpus green |
| M7 | Generators, rake tasks, README + usage guide, 0.1.0 release | A fresh Rails app goes from `bundle add` to a connected server in under 15 minutes following the README |
| M8 (v2) | `publish_action` (controller/Jbuilder → tool), MCP resources, tsvector search | — |

M0–M3 are the MVP: enough to publish real collections from a Rails app.

---

## 9. Decisions to make before M0

1. **Name and home**: `ror-mcp-server` / `RorMcp` (or `rails-mcp-server` / `RailsMcp`, which is easier to find on RubyGems). Check name availability. Public OSS or private gem server?
2. **Base SDK**: official `mcp` gem (recommended; tracks the spec) vs `fast-mcp` (has a Rails integration, but is a separate implementation). The gem only needs the protocol + transport layer, so pick the one with the more stable Streamable HTTP transport at M0.
3. **Default semantics**: `:fixed` for new apps (recommended) vs `:parity` by default.
4. **Minimum Rails**: 7.1 (recommended: composite PKs, modern multi-DB) or support 6.1.
5. **First consumer**: which Rails app adopts it first, and which of its models make up the first server. This keeps the API honest beyond the dummy app.

---

## 10. Assumptions to check

Everything marked ❓ is believed but **not verified**. Each one has a check and
what changes if it turns out wrong. Settle the ones marked **M0** before
writing code; settle the rest before the milestone named.

Status: ✅ verified · ❓ unverified · ⚠️ verified false (plan already adjusted).

### 10.1 The Ruby MCP SDK

| # | Assumption | How to check | If wrong |
|---|---|---|---|
| A1 ❓ **M0** | The official SDK is published as gem `mcp` (modelcontextprotocol/ruby-sdk) and is maintained | `gem info mcp -r`; GitHub activity, release cadence | Fall back to `fast-mcp`, or implement JSON-RPC + Streamable HTTP ourselves (≈ +1 milestone) |
| A2 ❓ **M0** | It exposes `MCP::Server`, `MCP::Tool`, `MCP::Tool::Response` and a **Streamable HTTP transport** (`MCP::Server::Transports::StreamableHTTPTransport` or similar) | `bundle open mcp`, read `lib/mcp/server*.rb` | Adjust `Server`/`Endpoint` wrapping; names in §4 are ours anyway |
| A3 ❓ **M0** | The transport can be driven from a Rack env (`handle_request(rack_request)` → `[status, headers, body]`) and mounted at an arbitrary path (respects `SCRIPT_NAME`) | Spike: mount it in a bare Rails app, `curl` initialize | Write our own Rack adapter in `endpoint.rb` (Django does the same with its ASGI bridge, §1A.2) |
| A4 ❓ **M0** | It can run **stateless**, so we own session rules ourselves, as django-mcp-server does (§1A.2) | Source + spike: `tools/call` without an SDK session | Endpoint implements JSON-RPC dispatch directly, using the SDK only for tool/schema types |
| A5 ❓ **M0** | It can return **plain JSON responses** (the `json_response=True` equivalent), not only SSE | Source + spike | Buffer the SSE stream and unwrap it in `Endpoint` |
| A6 ❓ M1 | It supports tool errors (`isError: true`) and embedded resources (needed for `output_as_resource`) | Source; spike a raising tool | Build the response payload by hand |
| A7 ❓ M1 | It negotiates the protocol versions current clients send (`2025-03-26`, `2025-06-18`, newer) | Spike with Claude Code and the MCP Inspector | Pin the client protocol in docs; contribute upstream |
| A8 ❓ M1 | Current MCP clients accept plain JSON (non-SSE) responses from a Streamable HTTP server. django-mcp-server relies on this | Spike with Claude Code, MCP Inspector, one more client | Add SSE output (moves from out-of-scope into v1) |
| A9 ❓ M0 | `fast-mcp` is a weaker base than the official SDK (Decision 2) | Compare both repos at M0: spec coverage, transport, issues | Swap the base; §2 mapping still holds |
| A10 ❓ M0 | The SDK's Ruby requirement is ≤ 3.2 (our stated minimum) | gemspec `required_ruby_version` | Raise our minimum Ruby |

### 10.2 django-mcp-server behaviour we promise parity with

Checked against the **0.5.7** source (`mcp_server/query_tool.py`,
`djangomcp.py`, `views.py`, `urls.py`, `apps.py`). Each item still gets a
parity-suite test, since reading code isn't running it.

| # | Assumption | Status / how to check | If wrong |
|---|---|---|---|
| A11 ✅ | Supported stages are `$lookup $match $sort $skip $limit $project $search $group`; `$match` ops `$eq $ne $gt $gte $lt $lte $in $nin $regex $text`, `$and $or $nor`, plus `extra_filters` as extended ops | `PIPELINE_DSL_SPEC`, `_parse_match` | — |
| A12 ✅ | `DjangoMCP(name, instructions, stateless)` exists; sessions are Django sessions; the SDK runs stateless with `json_response=True` | `djangomcp.py` `DjangoMCP.__init__`, `session_manager`, `handle_django_request` | — |
| A13 ⚠️ | ~~Results rename the PK to `_id`~~ Results are plain `.values()` rows: PK is `id`; `_id` only exists inside pipelines | `_QueryExecutor.query`. §1A.6 and §5 corrected | — |
| A14 ✅ / ❓ | `$lookup` only records an alias; `prefix = localField.replace("_id", "")` (✅ source). That `get_field` accepts the attname so `author_id` works as `localField` (❓, believed from Django's `_forward_fields_map`) | Parity test with both forms and with a mid-word `_id` field | Adjust the §1B row and the parity expectations |
| A15 ✅ | `$sum: 1` / `$count: 1` compile to `Count("id")` | `$group` branch of `apply_json_mango_query` | — |
| A16 ✅ | Only many-to-one `$lookup` (`local_field.many_to_one` check) | `_validate_lookup` | — |
| A17 ✅ | `$lookup` paths bypass the target toolset's `get_queryset()` and `fields`; with no `$project` all base-model columns are returned | Lookups become ORM `prefix__field` paths on the base queryset; `values()` without args | Then the fixed-mode rows in §1B are unneeded; keep for safety anyway |
| A18 ❓ M5 | Renderers beyond JSON (e.g. CSV) work through `DJANGO_MCP_OUTPUT_RENDERER_CLASSES` in practice | Parity app with a CSV renderer | Ship JSON only in v1 |
| A19 ❓ M2 | Keeping the `query_data_collections` description format verbatim (preamble + DSL spec + `$jsonSchema` + instructions) is worth it, because client prompts are tuned to it | Compare client behaviour with the verbatim vs a cleaner description on the dummy app | Free to redesign the description |
| A20 ✅ | Tool parameters are named `collection` and `search_pipeline` | `QueryTool._add_tools_to` | — |

### 10.3 Rails / ActiveRecord

| # | Assumption | How to check | If wrong |
|---|---|---|---|
| A21 ❓ M0 | Rails 7.1 is the right floor: composite PKs (7.1), `connected_to(role:/shard:)` (6.1), `while_preventing_writes` (6.0) | Rails changelogs; the first consumer's Rails version (Decision 5) | Lower floor → drop composite PK support or gate it |
| A22 ❓ M6 | `while_preventing_writes` lets `SET TRANSACTION READ ONLY` / `SET LOCAL statement_timeout` through | Spike on PG and MySQL; read AR `write_query?` / `READ_QUERY` per adapter | Issue those statements before entering the guard |
| A23 ❓ M6 | `while_preventing_writes` alone is not a sufficient read-only guarantee (it inspects SQL text only), so a DB-level `READ ONLY` transaction is needed too | A `computed sql:` calling a side-effecting function | — (already planned; also recommend a read-only DB role in docs) |
| A24 ❓ M3 | Arel can build `belongs_to` joins with **client-chosen table aliases** (`as`) and chain them (`a1.a2.field`), including self-joins | Spike `Arel::Table.new(t, as: alias)` joins | Generate internal aliases and map client aliases onto them |
| A25 ❓ M3 | A target collection's `scope(context)` can be applied as a join condition (fixed mode) | Spike: `scope.where_clause` merged into the join `ON`, or a subquery join | Use `INNER JOIN (scope SQL) AS alias`; document the cost |
| A26 ❓ M2 | `Rails.autoloaders.main.eager_load_dir` (Zeitwerk ≥ 2.6) works in a railtie for `app/mcp` in dev with reloading | Spike in dummy app; edit a collection, reload | Explicit `RorMcp.register` calls or a `to_prepare` hook |
| A27 ❓ M3 | `reflect_on_association` + STI/subclass checks resolve references the way §3 promises | Specs with STI models and `class_name:` associations | Require explicit `reference … to:` |
| A28 ❓ M2 | `defined_enums` and column comments give useful schema descriptions | Column comments exist on PG/MySQL, not on SQLite | Fall back to a `describe :field, "…"` DSL |
| A29 ❓ M3 | `$regex` can be supported on all three adapters | SQLite has no built-in `REGEXP`; needs a registered function | SQLite: `$regex` unsupported with a clear error |
| A30 ❓ M2 | `Rails.cache` is a valid shared session store | Only if the app uses Redis/Memcached; `memory_store` and `file_store` are per-process | Document it, and raise at boot when `session_store = :cache` with a non-shared cache in production |
| A31 ❓ M1 | Multi-process Puma / several hosts break `:memory` sessions | Known for any per-process store | — (only changes the documented default) |

### 10.4 Testing and process

| # | Assumption | How to check | If wrong |
|---|---|---|---|
| A32 ❓ M0 | A minimal Django project with django-mcp-server 0.5.7 can run in the gem's CI next to the Rails dummy app on the same database | CI spike: Python + Ruby in one job, shared Postgres service | Generate expected outputs offline and commit them as fixtures |
| A33 ❓ M2 | Django and Ruby results can be compared deterministically | Pipelines without `$sort` have undefined order; float/decimal/date encodings differ | Corpus uses sorted pipelines only; normalise numbers/dates before diffing |
| A34 ❓ M6 | The "wide model hides every collection" failure comes from a client-side truncation limit on tool descriptions, and 25k chars is under it | Measure with Claude Code and other clients on the dummy app, growing the description until collections disappear | Tune the `description_budget` default |
| A35 ❓ M7 | An MCP client can run headless in CI for the smoke test | Try Claude Code CLI and the MCP Inspector CLI in a clean container | Use an SDK-based MCP client (Ruby or Python) instead |
| A36 ❓ M0 | Target clients send configured headers on every request, so static bearer auth is enough | Check Claude Code, Claude Desktop, MCP Inspector configs | Add OAuth (out of scope for v1) |

### 10.5 Product and naming

| # | Assumption | How to check | If wrong |
|---|---|---|---|
| A37 ❓ M0 | `ror-mcp-server` / `rails-mcp-server` are free on RubyGems and the `RorMcp` constant doesn't collide | `gem search -e ror-mcp-server rails-mcp-server`; GitHub search | Pick another name (Decision 1) |
| A38 ❓ M0 | No existing gem already does this (ActiveRecord collections + Mongo-style pipeline over MCP) | Search RubyGems/GitHub for "mcp activerecord", "rails mcp server" | Contribute to or build on it instead |
| A39 ❓ M0 | A real Rails app needs this soon enough to act as first consumer (Decision 5) | Name the app and its first server's models | Build against the dummy app only; risk of an over-generic API |
