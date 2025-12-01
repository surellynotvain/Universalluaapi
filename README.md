# Universal REST - HTTP/REST Client for Lua

A compact, single-file Lua HTTP/REST client designed for any Lua project. Features environment-adaptive adapters (LuaSocket / lua-resty-http), JSON helpers, retries with exponential backoff, TTL caching, token-bucket rate limiting, WebSocket support, and multi-server failover.

**Current Version:** 0.2.1

---

## Quick Start

### 1. Installation

Copy `universal_rest.lua` into your project:

```bash
cp universal_rest.lua /path/to/your/project/
```

### 2. Basic Usage

```lua
local rest = require("universal_rest")

-- Initialize with configuration
rest.init{
  timeout = 8000,                    -- milliseconds
  retries = 3,
  logger = function(... ) print("[REST]", ...) end,
  rate_limits = {
    ["api.example.com"] = { capacity = 5, refill_per_sec = 1 }
  },
}

-- Simple GET request
local status, body, headers, err = rest.get("https://httpbin.org/get")
if not status then
  print("Error:", err)
else
  print("Status:", status)
  print("Body:", body)
end
```

### 3.  JSON Convenience Methods

```lua
-- GET JSON (auto-decode)
local status, data, err = rest.get_json("https://api.example.com/users")
if status then
  print("Users:", data)
  for _, user in ipairs(data. results or {}) do
    print(" -", user.name)
  end
else
  print("JSON error:", err)
end

-- POST JSON (auto-encode)
local status, response, err = rest.post_json(
  "https://api.example.com/users",
  { name = "John Doe", email = "john@example.com" }
)
if status then
  print("Created user:", response.id)
end
```

### 4. Advanced Features

```lua
-- Authentication
local status, body = rest.request("GET", "https://api.example.com/data", {
  bearer = "your-token-here"
})

-- Basic auth
local status, body = rest.request("GET", "https://api.example.com/protected", {
  basic = { user = "username", pass = "password" }
})

-- Caching
local status, data = rest.get_json("https://api.example.com/config", {
  cache_ttl = 300  -- Cache for 5 minutes
})

-- Custom headers
local status, body = rest.post("https://api.example.com/webhook", {
  headers = { ["X-Custom-Header"] = "value" },
  body = "raw body data"
})
```

---

## API Reference

### `rest.init(opts)`

Initialize with configuration.  Call before making requests.

**Parameters:**
```lua
rest.init{
  -- Timeouts & Retries
  timeout = 5000,              -- Request timeout (ms)
  retries = 2,                 -- Number of retries
  backoff_base = 200,          -- Base backoff (ms)
  backoff_factor = 2,          -- Exponential factor
  jitter = true,               -- Add randomness to backoff
  
  -- Identifiers
  user_agent = "universal_rest/1.0",
  
  -- JSON Codec (auto-detected if available)
  json = {
    encode = function(t) ...  end,
    decode = function(s) ... end
  },
  
  -- Logging
  logger = function(... ) print(... ) end,
  
  -- Rate Limiting
  rate_limits = {
    ["api.example.com"] = {
      capacity = 10,           -- Tokens
      refill_per_sec = 2       -- Refill rate
    }
  },
  
  -- Caching
  cache_enabled = true,
  cache_max_items = 1000,
  
  -- Servers (for failover)
  servers = {
    "https://api1.example.com",
    "https://api2.example.com",
    "http://localhost:8000"
  },
  prefer_localhost = true,
  
  -- WebSocket
  websocket = {
    enabled = true,
    library = "websocket. client"  -- or "websocket"
  }
}
```

### HTTP Methods

```lua
-- GET
local status, body, headers, err = rest. get(url, opts)

-- POST
local status, body, headers, err = rest. post(url, opts)

-- PUT
local status, body, headers, err = rest.put(url, opts)

-- DELETE
local status, body, headers, err = rest.delete(url, opts)

-- Custom method
local status, body, headers, err = rest.request("PATCH", url, opts)
```

**Request Options:**
```lua
{
  headers = { ["Custom-Header"] = "value" },
  body = "raw string or encoded data",
  json = true,                 -- Auto-encode body as JSON
  cache_ttl = 300,            -- Cache response (seconds)
  retries = 3,                -- Override default retries
  timeout_ms = 10000,         -- Override timeout
  bearer = "token",           -- Bearer token auth
  basic = { user = "u", pass = "p" },  -- Basic auth
  rate_cost = 1               -- Rate limit cost (tokens)
}
```

### JSON Methods

```lua
-- GET and decode JSON
local status, data, err = rest.get_json(url, opts)

-- POST and encode/decode JSON
local status, data, err = rest.post_json(url, table_data, opts)
```

### Batch Requests

```lua
local results = rest.batch({
  { method = "GET", url = "https://api.example.com/users" },
  { method = "POST", url = "https://api.example.com/items",
    opts = { json = true, body = { name = "item" } }
  },
})

for i, result in ipairs(results) do
  print(i, result.status, result.err)
  if result.body then
    print("  Body:", result.body)
  end
end
```

### WebSocket

```lua
-- Connect with handlers
local ws, err = rest.ws_connect("ws://echo.websocket.org", {
  on_message = function(msg)
    print("Received:", msg)
  end,
  on_close = function()
    print("Connection closed")
  end,
  on_error = function(err)
    print("Error:", err)
  end
})

if not ws then
  print("Connect failed:", err)
  return
end

-- Send message
ws. send("Hello, WebSocket!")

-- Close connection
ws.close()
```

### Network Helpers

```lua
-- UDP hole-punch (P2P)
local ok, err = rest.udp_holepunch(
  12345,                    -- Local port
  "203.0.113.45",          -- Peer IP
  54321,                    -- Peer port
  5,                        -- Attempts
  0.2                       -- Interval (seconds)
)

-- Signaling helpers (for WebRTC)
local status, data = rest.signal_offer("signal/offer", {
  from = "alice",
  to = "bob",
  sdp = offer_sdp
})

-- TURN allocator
local status, turn_data = rest.request_turn("turn", {})
```

### URL Utilities

```lua
-- Build URL with query parameters
local url = rest.build_url("https://api.example.com/search", {
  q = "lua",
  limit = 10
})
-- Result: https://api.example.com/search?q=lua&limit=10
```

---

## Configuration Examples

### Using cJSON (Fastest)

```lua
local cjson = require("cjson")
rest.init{
  json = {
    encode = cjson.encode,
    decode = cjson.decode
  }
}
```

### Rate Limiting

```lua
rest. init{
  rate_limits = {
    ["api.example. com"] = {
      capacity = 100,          -- Max 100 tokens
      refill_per_sec = 10      -- Refill 10/second (100/10sec = 10 req/sec)
    },
    ["other-api.com"] = {
      capacity = 50,
      refill_per_sec = 1       -- 1 request per second
    }
  }
}

-- Rate limiting errors appear in logs
-- Handle with retries (automatic)
local status, body = rest.get("https://api.example.com/data")
```

### Multi-Server Failover

```lua
rest.init{
  servers = {
    "https://api. example.com",      -- Primary (tried first)
    "https://api-backup.example.com",
    "http://localhost:3000"         -- Local fallback
  },
  prefer_localhost = true           -- Try localhost first
}

-- Requests automatically failover
local status, body = rest.get("/data")
-- Tries: localhost:3000 → api-backup → api.example.com
```

### Custom Logging

```lua
rest. init{
  logger = function(tag, ...)
    local args = {...}
    local msg = table.concat(args, " ")
    io.stderr:write(
      os.date("%Y-%m-%d %H:%M:%S"),
      " [",
      tag,
      "] ",
      msg,
      "\n"
    )
  end
}
```

---

## Common Patterns

### Retrying Failed Requests

```lua
local function make_request_with_fallback()
  local rest = require("universal_rest")
  rest.init{ retries = 3, backoff_base = 100 }
  
  local status, body, headers, err = rest.get("https://api.example.com/data")
  
  if not status then
    print("All retries failed:", err)
    return nil
  end
  
  return body
end
```

### JSON Response Parsing

```lua
local rest = require("universal_rest")

local status, users, err = rest.get_json("https://api.example. com/users")

if not status then
  print("Request failed:", err)
elseif status ~= 200 then
  print("Server returned:", status)
else
  -- Process users array
  for i, user in ipairs(users) do
    print(i, user.id, user.name)
  end
end
```

### Error Handling

```lua
local rest = require("universal_rest")

local function safe_api_call(url)
  local status, body, headers, err = rest.get(url)
  
  if not status then
    -- Network error
    return nil, "network_error", err
  end
  
  if status >= 400 and status < 500 then
    -- Client error (4xx)
    return nil, "client_error", status
  end
  
  if status >= 500 then
    -- Server error (5xx)
    return nil, "server_error", status
  end
  
  return body, nil
end
```

### Authenticated Requests

```lua
local rest = require("universal_rest")

-- Bearer token
local status, data = rest.get_json("https://api.example.com/profile", {
  bearer = os.getenv("API_TOKEN")
})

-- Basic authentication
local status, data = rest. get_json("https://api. example.com/data", {
  basic = {
    user = os.getenv("API_USER"),
    pass = os.getenv("API_PASS")
  }
})
```

---

## Dependencies

### Required
- **Lua 5.1+** (5.3+ recommended)

### Optional (Auto-Detected)
- **luasocket** + **ltn12** - Default HTTP adapter
- **lua-resty-http** - For OpenResty/nginx environments
- **dkjson** or **cjson** - For JSON (fallback encoder included)
- **lua-websocket** - For WebSocket support
- **mime** - For base64 encoding in basic auth

### Installation

**LuaSocket (Ubuntu/Debian):**
```bash
sudo apt-get install lua-socket lua-sec
```

**LuaRocks:**
```bash
luarocks install lua-socket
luarocks install dkjson
```

**OpenResty:**
```bash
# Already includes resty. http
opm get openresty/lua-resty-http
```

---

## Troubleshooting

### "no supported HTTP adapter"
**Problem:** Neither luasocket nor lua-resty-http available  
**Solution:**
```bash
# Install luasocket
luarocks install lua-socket
# Or use OpenResty with lua-resty-http
```

### Timeout errors
**Problem:** Requests timeout unexpectedly  
**Solution:**
```lua
-- Increase timeout
rest.init{ timeout = 15000 }  -- 15 seconds

-- Or per-request
rest.get(url, { timeout_ms = 30000 })
```

### "rate_limited" in logs
**Problem:** Rate limiting too aggressive  
**Solution:**
```lua
-- Adjust rate limits
rest.init{
  rate_limits = {
    ["api.example.com"] = {
      capacity = 100,
      refill_per_sec = 20
    }
  }
}
```

### JSON decode errors
**Problem:** Can't decode JSON responses  
**Solution:**
```lua
-- Use better JSON library
local cjson = require("cjson")
rest.init{ json = { encode = cjson.encode, decode = cjson.decode } }

-- Or check response body
local status, body = rest. get(url)
print("Raw response:", body)  -- Debug
```

### WebSocket connection fails
**Problem:** WebSocket not available  
**Solution:**
```bash
# Install lua-websocket
luarocks install lua-websocket
```

---

## Performance Tips

### 1. Connection Pooling (OpenResty)
Automatic with v0.2.1 - no configuration needed

### 2.  Request Caching
```lua
-- Cache JSON responses for 5 minutes
local status, data = rest.get_json(url, { cache_ttl = 300 })
```

### 3. Batch Requests
```lua
-- Sequential but efficient
local results = rest.batch({
  { method = "GET", url = url1 },
  { method = "GET", url = url2 },
  { method = "GET", url = url3 },
})
```

### 4. Rate Limiting
```lua
-- Prevents overload
rest.init{
  rate_limits = { ["api.example.com"] = { capacity = 10, refill_per_sec = 1 } }
}
```

### 5. Use Local Servers
```lua
-- Prefer localhost if available
rest.init{
  servers = { "http://localhost:3000", "https://remote.api.com" },
  prefer_localhost = true
}
```

---

## Use Cases

### Mobile App Backend
```lua
rest.init{
  timeout = 10000,
  retries = 3,
  servers = { "https://api.myapp.com", "https://api-backup.myapp.com" }
}

-- Handle poor connectivity with retries
local data = rest.get_json("/user/profile")
```

### Game Server
```lua
rest.init{
  rate_limits = { ["matchmaker.game. com"] = { capacity = 100, refill_per_sec = 10 } }
}

-- Rate-limited matchmaking requests
rest.post_json("/match/find", { player_id = 123 })
```

### IoT Device
```lua
rest.init{
  timeout = 5000,
  cache_enabled = true,
  servers = { "http://192.168.1.100:8000" }
}

-- Cached config fetches, local preference
local config = rest.get_json("/device/config", { cache_ttl = 600 })
```

### Web Service
```lua
rest.init{
  servers = { "http://localhost:3000", "http://api.external.com" },
  prefer_localhost = true
}

-- Transparent failover to external API
local data = rest.get_json("/data")
```

---

## What's NOT Included

This library is for **control-plane** tasks (config, auth, signaling).  For **data-plane** use:

- **Real-time chat** → Use WebSocket library directly
- **File streaming** → Use dedicated HTTP client
- **P2P video** → Use WebRTC library  
- **Game networking** → Use ENet or QUIC library

---

## Architecture

### Request Flow
```
rest.get(url, opts)
  ├─ build_candidates(url)  - Failover URLs
  ├─ cache_get(key)         - Check cache
  ├─ rate_acquire(host)     - Rate limit check
  ├─ perform_raw_request()  - Choose adapter
  │  ├─ OpenResty path (ngx_available)
  │  └─ LuaSocket path (has_luasocket)
  ├─ cache_set(key, body)   - Cache response
  └─ return status, body, headers, err
```

### Adapters
- **OpenResty** - Uses `lua-resty-http` (high performance)
- **LuaSocket** - Default (portable, compatible)
- **Fallback** - Error if neither available

### Internal Functions
```lua
M._internal. perform_raw_request()  -- Raw HTTP adapter
M._internal.cache_get/set()        -- Cache operations  
M._internal.rate_acquire()         -- Rate limiting
M._internal.build_candidates()     -- URL failover
```

## License

MIT - Adapt and reuse freely. 
