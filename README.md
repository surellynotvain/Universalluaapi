# universal_rest — README

A compact single-file Lua HTTP/REST client designed to be dropped into any Lua project. It provides environment-adaptive adapters (LuaSocket / lua-resty-http), JSON helpers, retries with exponential backoff, TTL caching for GETs, token-bucket rate limiting, and simple batch helpers.

---

## Quick start

1. Copy `universal_rest.lua` into your project directory.
2. From your Lua code:

```lua
local rest = require("universal_rest")
rest.init{
  timeout = 8000, -- milliseconds
  retries = 3,
  logger = function(...) print("[REST]", ...) end,
  rate_limits = { ["api.example.com"] = { capacity = 5, refill_per_sec = 1 } },
}

-- simple GET
local status, body, headers, err = rest.get("https://httpbin.org/get")
if not status then
  print("error:", err)
else
  print("status:", status)
  print(body)
end

-- GET JSON convenience
local status, data, err = rest.get_json("https://api.example.com/data")
if status then
  -- data is decoded Lua table
  print("got fields:", data.someField)
else
  print("json error:", err)
end

-- POST JSON
local status, resp, err = rest.post_json("https://api.example.com/items", { name = "item" })

-- batch (sequential fallback)
local results = rest.batch({
  { method = "GET", url = "https://httpbin.org/get" },
  { method = "POST", url = "https://httpbin.org/post", opts = { json = true, body = { a=1 } } },
})

for i,r in ipairs(results) do
  print(i, r.status, r.err)
end
```

---

## API reference (short)

* `rest.init(opts)` — set runtime defaults. Common `opts`:

  * `timeout` (ms), `retries`, `backoff_base`, `backoff_factor`, `jitter` (bool)
  * `user_agent` (string)
  * `json` (table with `encode`/`decode` functions) — set to `cjson`, `dkjson`, etc.
  * `logger` (fn)
  * `rate_limits` (table: host -> `{ capacity, refill_per_sec }`)
  * `cache_enabled`, `cache_max_items`

* `status, body, headers, err = rest.request(method, url, opts)` — core call. `opts` supports:

  * `headers` table
  * `body` string or table (use `opts.json=true` to auto-encode)
  * `json = true` — encode `opts.body` as JSON
  * `cache_ttl` — seconds for GET caching
  * `retries`, `timeout_ms`, `bearer`, `basic` (table `{ user, pass }`)

* Convenience: `rest.get`, `rest.post`, `rest.put`, `rest.delete`, `rest.get_json`, `rest.post_json`, `rest.batch`, `rest.build_url`

---

## Config examples

**Use cjson for speed**

```lua
local cjson = require("cjson")
rest.init{ json = { encode = cjson.encode, decode = cjson.decode } }
```

**Rate-limit specific host**

```lua
rest.init{ rate_limits = { ["api.example.com"] = { capacity = 10, refill_per_sec = 2 } } }
```

**Set a custom logger**

```lua
rest.init{ logger = function(tag, ...) io.stderr:write(tag, " ", table.concat({...}," "), "\n") end }
```

---

## Using `universal_rest` for P2P + chat (signaling layer)

`universal_rest` is designed for control-plane tasks: matchmaking, presence, signaling (exchanging SDP/ICE), TURN credential requests, and relay control. It is not a real-time data transport. Use it together with a data-plane technology:

* **WebRTC** — use `rest.post_json` to send offers/answers and ICE candidates between peers (signaling). WebRTC handles encrypted P2P data/voice channels.
* **WebSocket** — use a WebSocket implementation for live text chat; use `universal_rest` for history and presence.
* **ENet / UDP** — use `rest` to fetch peer lists and coordinate hole punching; use ENet for the low-latency game traffic.

Example: WebRTC signaling pseudo-flow

```lua
-- A creates offer in WebRTC library (not included)
rest.post_json("https://signal.example.com/offer", { from = "A", to = "B", sdp = offer_sdp })
-- B polls or receives via separate channel, replies with answer
rest.post_json("https://signal.example.com/answer", { from = "B", to = "A", sdp = answer_sdp })
```

---

## Dependencies & environment

* Recommended: `luasocket` + `ltn12` (for default adapter). Many environments already include these.
* Optional for speed: `lua-cjson` or `dkjson` for JSON encode/decode.
* Optional for OpenResty: `lua-resty-http` (module auto-detects and uses it if present).
* Optional additions for P2P features: `lua-websocket`, `lua-enet`, `lua-webrtc` bindings (if available for target platform).

---

## Extending the module

* Add a WebSocket adapter and expose `ws.connect()` helper.
* Add a TURN allocation helper (`requestTurn()`): call your TURN allocator endpoint and cache credentials.
* Replace the batch implementation with coroutine- or thread-based concurrency if your environment supports it.
* Add persistent cache (Redis/LMDB) by replacing internal `cache_get`/`cache_set`.

---

## Troubleshooting

* **No HTTP adapter found**: install `luasocket` or run inside OpenResty with `lua-resty-http`.
* **JSON decode errors**: configure `rest.init{ json = { ... } }` to use a compatible JSON library.
* **Rate-limited**: adjust `rate_limits` or handle `rate_limited` error from `request`.

---

## License

MIT — adapt and reuse freely.

*End of v1.1.0 notes.*
