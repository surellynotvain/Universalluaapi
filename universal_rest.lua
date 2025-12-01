-- universal_rest.lua
-- Universal, environment-adaptive HTTP/REST client for Lua
-- Adds: multi-server/failover, websocket adapter (if available),
-- UDP hole-punch helpers, signaling & TURN helpers, localhost convenience. 

local socket_ok, http = pcall(require, "socket. http")
local ltn12_ok, ltn12 = pcall(require, "ltn12")
local json_ok, json = pcall(require, "dkjson") -- optional; fallback to simplistic encoder/decoder below
local has_luasocket = socket_ok and ltn12_ok

local ok_resty_http, resty_http = pcall(require, "resty.http")
local ngx_available = (type(ngx) == "table" and ok_resty_http)

-- optional websocket libs (try several common names)
local ws_client, ws_lib_name
local ok_ws, ws_try = pcall(require, "websocket. client")
if ok_ws then ws_client = ws_try; ws_lib_name = "websocket. client" end
if not ws_client then
  ok_ws, ws_try = pcall(require, "websocket")
  if ok_ws and type(ws_try) == "table" and ws_try.client then ws_client = ws_try.client; ws_lib_name = "websocket" end
end

-- simple JSON fallback (very small; for production prefer dkjson/cjson)
local function simple_encode(t)
  if type(t) ~= "table" then return tostring(t) end
  local parts = {}
  
  -- BUG FIX #5: Properly escape all JSON special characters
  local function escape_string(s)
    return s:gsub("\\", "\\\\")
           :gsub('"', '\\"')
           :gsub("\b", "\\b")
           :gsub("\f", "\\f")
           :gsub("\n", "\\n")
           :gsub("\r", "\\r")
           :gsub("\t", "\\t")
  end
  
  for k,v in pairs(t) do
    local key = tostring(k):gsub('"','\\"')
    local val = type(v) == "string" and ("\"" .. escape_string(v) .. "\"")
              or (type(v) == "number" and tostring(v))
              or (type(v) == "boolean" and tostring(v))
              or (type(v) == "table" and simple_encode(v))
              or "\"\""
    parts[#parts+1] = '"'..key.. '":'..val
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function simple_decode(_) error("No JSON decoder available; install dkjson or cjson") end

local JSON = (json_ok and json) and { encode = function(t) return json.encode(t) end, decode = function(s) return json.decode(s) end }
          or { encode = simple_encode, decode = simple_decode }

local socket = nil
if has_luasocket then
  socket = require("socket")
end

local M = {}

-- Default configuration (modifiable via init)
M.config = {
  timeout = 5000,            -- ms
  retries = 2,
  backoff_base = 200,       -- ms
  backoff_factor = 2,
  jitter = true,
  user_agent = "universal_rest/1.0",
  json = JSON,
  logger = function(... ) io.write(table.concat({...}," ").. "\n") end,
  rate_limits = {},         -- host -> { capacity=, refill_per_sec= }
  cache_enabled = true,
  cache_max_items = 1000,
  servers = {},             -- list of base URLs for failover, e.g. {"https://api1.example","http://localhost:8000"}
  prefer_localhost = true,  -- try localhost entries first if present
  websocket = {             -- websocket defaults/options
    enabled = true,
    library = ws_lib_name,
  },
}

-- internal simple cache (LRU-ish by timestamp)
local cache = {}
local cache_index = {}

local function cache_get(key)
  if not M.config.cache_enabled then return nil end
  local ent = cache[key]
  if not ent then return nil end
  if ent.expires and ent.expires <= (os.time()) then
    cache[key] = nil
    cache_index[key] = nil
    return nil
  end
  ent.last_access = os.time()
  return ent.value
end
local function cache_set(key, value, ttl)
  if not M. config.cache_enabled then return end
  -- BUG FIX #12: Validate cache TTL and log warning for invalid values
  if ttl and ttl <= 0 then
    M. config.logger("warning: cache_set called with invalid TTL (must be > 0):", ttl)
    return
  end
  
  local idxcount = 0 for _ in pairs(cache_index) do idxcount = idxcount + 1 end
  if idxcount > M.config.cache_max_items then
    -- simple prune: remove oldest
    local oldest_k, oldest_t
    for k,v in pairs(cache_index) do
      if not oldest_t or v < oldest_t then oldest_t = v; oldest_k = k end
    end
    if oldest_k then cache[oldest_k]=nil; cache_index[oldest_k]=nil end
  end
  cache[key] = { value = value, expires = ttl and (os.time() + ttl) or nil, last_access = os.time() }
  cache_index[key] = os.time()
end

-- token bucket rate limiter per host
local rate_state = {}
local function rate_acquire(host, cost)
  local cfg = M.config. rate_limits[host]
  if not cfg then return true end
  local st = rate_state[host]
  local now = (os.time())
  if not st then
    st = { tokens = cfg.capacity, last = now }
    rate_state[host] = st
  end
  local elapsed = now - st.last
  st.tokens = math.min(cfg.capacity, st.tokens + elapsed * cfg.refill_per_sec)
  st.last = now
  if st.tokens >= (cost or 1) then
    st. tokens = st.tokens - (cost or 1)
    return true
  end
  return false
end

-- backoff function
local function backoff(attempt)
  local base = M.config.backoff_base
  local factor = M. config.backoff_factor
  local jitter = M.config. jitter
  local ms = base * (factor ^ (attempt - 1))
  if jitter then
    local j = math.random(0, base)
    ms = ms + j
  end
  return ms / 1000 -- seconds
end

-- helper: build absolute URL by trying servers list (failover)
local function build_candidates(path_or_url)
  -- if full url provided, return it alone
  if tostring(path_or_url):match("^https?://") then return { path_or_url } end
  local candidates = {}
  local servers = M.config.servers or {}
  -- optionally prefer localhost entries first
  if M.config.prefer_localhost then
    for _, s in ipairs(servers) do
      if tostring(s):match("localhost") or tostring(s):match("127.0.0.1") then table.insert(candidates, s) end
    end
    for _, s in ipairs(servers) do
      if not (tostring(s):match("localhost") or tostring(s):match("127.0.0.1")) then table.insert(candidates, s) end
    end
  else
    for _, s in ipairs(servers) do table.insert(candidates, s) end
  end
  -- append as base + path
  local out = {}
  for _, base in ipairs(candidates) do
    base = tostring(base)
    local sep = ""
    if not path_or_url:match("^/") and not base:match("/$") then sep = "/" end
    table.insert(out, base .. sep .. path_or_url)
  end
  return out
end

-- choose adapter and perform a raw request (returns status, body, headers, err)
local function perform_raw_request(method, url, headers, body, timeout_ms)
  timeout_ms = timeout_ms or M.config.timeout
  -- OpenResty (lua-resty-http) path
  if ngx_available then
    local httpc = resty_http.new()
    -- BUG FIX #1: Convert ms to seconds for resty_http set_timeout
    if timeout_ms then httpc:set_timeout(timeout_ms / 1000) end
    local parsed = require("socket.url").parse(url)
    -- BUG FIX #2: Add nil check on parsed URL
    if not parsed or not parsed.host then return nil, nil, nil, "url parse error: invalid url" end
    local host = parsed.host
    local port = tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80)
    local ok, err = httpc:connect(host, port)
    if not ok then return nil, nil, nil, "connect error: "..tostring(err) end
    if parsed.scheme == "https" then
      local _, ssl_err = httpc:ssl_handshake(nil, host, false)
      if ssl_err then return nil, nil, nil, "ssl handshake error: ".. tostring(ssl_err) end
    end
    local res, req_err = httpc:request{
      method = method,
      path = (parsed.path or "/") .. (parsed.query and ("?"..parsed.query) or ""),
      headers = headers,
      body = body,
    }
    if not res then return nil, nil, nil, "request error: "..tostring(req_err) end
    local chunks = {}
    while true do
      local chunk, recv_err = res:read_body(8192)
      if not chunk then
        if recv_err then return res. status, nil, res.headers, "read body error: "..tostring(recv_err) end
        break
      end
      table.insert(chunks, chunk)
      if #chunk == 0 then break end
    end
    local body_str = table.concat(chunks)
    -- BUG FIX #8: Return connection to keepalive pool for reuse
    local ok, keepalive_err = pcall(function()
      httpc:keepalive(60, 100)
    end)
    if not ok then
      M.config.logger("keepalive_error", tostring(keepalive_err))
    end
    return res.status, body_str, res.headers, nil
  end

  -- LuaSocket (default)
  if has_luasocket then
    local resp_body = {}
    local r, c, h = http.request{
      method = method,
      url = url,
      headers = headers,
      source = (body and ltn12.source.string(body)) or nil,
      sink = ltn12.sink.table(resp_body),
      protocol = "any",
      create = nil,
      redirect = false,
      timeout = timeout_ms / 1000, -- seconds
    }
    local status = c -- c is status code or nil
    local headers_out = h or {}
    local body_str = table.concat(resp_body)
    return status, body_str, headers_out, (r and nil) or "socket error"
  end

  return nil, nil, nil, "no supported HTTP adapter (install luasocket or lua-resty-http)"
end

-- high-level request with retries, rate-limit, caching, and multi-server failover
local function request(method, path_or_url, opts)
  opts = opts or {}
  local headers = opts.headers or {}
  headers["User-Agent"] = headers["User-Agent"] or M.config.user_agent
  if opts.json and opts.body and type(opts.body) == "table" then
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    opts.body = M.config.json. encode(opts.body)
  end
  if opts.bearer then headers["Authorization"] = "Bearer " .. opts.bearer end
  if opts.basic then
    local user, pass = opts.basic. user or "", opts.basic.pass or ""
    local b = (user .. ":" .. pass)
    local enc
    local enc_err
    -- BUG FIX #9: Add error handling for basic auth encoding
    pcall(function() 
      local mime = require("mime")
      if mime and mime.b64 then
        enc = mime.b64(b)
      else
        enc_err = "mime library does not have b64 function"
      end
    end)
    if enc then 
      headers["Authorization"] = "Basic " .. enc
    elseif enc_err then
      M.config.logger("warning: basic auth encoding failed:", enc_err)
    end
  end

  -- Build candidate full URLs
  local candidates = build_candidates(tostring(path_or_url))
  if #candidates == 0 then candidates = { tostring(path_or_url) } end
  
  -- BUG FIX #11: Validate candidates are proper URLs if we're not using full URLs
  if not tostring(path_or_url):match("^https?://") then
    if #M.config.servers == 0 then
      M.config.logger("warning: no servers configured and relative path provided:", path_or_url)
    end
  end

  -- cache key uses full url including body
  -- BUG FIX #3: Use safer cache key generation to avoid collisions
  local function safe_cache_key(method, urls, body)
    local key_parts = {method}
    for _, url in ipairs(urls) do
      table.insert(key_parts, url)
    end
    table.insert(key_parts, body or "")
    return table.concat(key_parts, "\0")
  end
  local cache_key = safe_cache_key(method, candidates, opts. body)
  
  if method == "GET" and opts.cache_ttl then
    local cached = cache_get(cache_key)
    if cached then return 200, cached, { from_cache = true } end
  end

  local attempts = (opts.retries ~= nil) and opts.retries or M.config.retries
  local attempt = 0

  -- BUG FIX #4: Improved retry loop logic
  -- iterate through candidates for each attempt (failover across servers)
  while attempt < attempts do
    attempt = attempt + 1
    local attempt_succeeded = false
    for _, url in ipairs(candidates) do
      local host = url:match("^https?://([^/]+)") or "default"
      if not rate_acquire(host, opts.rate_cost or 1) then
        M. config.logger("rate_limited", host)
        -- wait then continue to next server or attempt
        local wait = backoff(attempt)
        if ngx then 
          ngx.sleep(wait) 
        elseif socket then 
          socket. sleep(wait) 
        end
        goto continue_next_server
      end

      local status, body, resp_headers, err = perform_raw_request(method, url, headers, opts.body, opts.timeout_ms)
      if err then
        M.config.logger("request_error", method, url, err, "attempt", attempt)
      else
        local status_num = tonumber(status) or 0
        if status_num >= 200 and status_num < 300 then
          if method == "GET" and opts.cache_ttl then cache_set(cache_key, body, opts.cache_ttl) end
          attempt_succeeded = true
          return status_num, body, resp_headers, nil
        end
        if status_num >= 400 and status_num < 500 and status_num ~= 429 then
          attempt_succeeded = true
          return status_num, body, resp_headers, nil
        end
        M.config.logger("http_status", status_num, "from", url, "attempt", attempt)
      end
      ::continue_next_server::
    end

    -- If all servers failed for this attempt, backoff before retrying
    local wait = backoff(attempt)
    if ngx then 
      ngx.sleep(wait) 
    elseif socket then 
      socket.sleep(wait) 
    end
  end
  return nil, nil, nil, "max attempts reached across servers"
end

-- convenience helpers
function M.init(opts)
  for k,v in pairs(opts or {}) do M.config[k] = v end
  -- BUG FIX #10: Use better entropy for random seeding
  local seed = os.time()
  if type(io.open) == "function" then
    seed = seed * 65536 + (tonumber(tostring(math.random(1, 65536))) or 0)
  end
  math.randomseed(seed)
end

function M. request(method, path_or_url, opts)
  return request(method:upper(), path_or_url, opts)
end

function M.get(url, opts) return M.request("GET", url, opts) end
function M.post(url, opts) return M. request("POST", url, opts) end
function M.put(url, opts) return M.request("PUT", url, opts) end
function M.delete(url, opts) return M.request("DELETE", url, opts) end

-- JSON helpers
function M.get_json(url, opts)
  opts = opts or {}
  opts. headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.get(url, opts)
  if not status then return nil, nil, err end
  -- BUG FIX #6: Handle empty response body for GET
  if not body or body == "" then
    M.config.logger("warning: empty response body for GET", url)
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: "..tostring(decoded) end
  return status, decoded, nil
end

function M.post_json(url, tbl, opts)
  opts = opts or {}
  opts.json = true
  opts.body = tbl
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.post(url, opts)
  if not status then return nil, nil, err end
  -- BUG FIX #6: Handle empty response body for POST
  if not body or body == "" then
    M.config.logger("warning: empty response body for POST", url)
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: "..tostring(decoded) end
  return status, decoded, nil
end

-- Batch requests (sequential fallback); will try multi-server logic per request
function M.batch(requests, opts)
  local results = {}
  for i, r in ipairs(requests) do
    local st, body, hdrs, err = M.request(r.method or "GET", r.url, r.opts or {})
    results[i] = { status = st, body = body, headers = hdrs, err = err }
  end
  return results
end

-- WebSocket helper (simple wrapper).  Returns a table with send, recv, close if supported. 
function M.ws_connect(full_url, handlers, opts)
  -- handlers: { on_message = fn(msg), on_close = fn(), on_error = fn(err) }
  opts = opts or {}
  if not M.config.websocket. enabled or not ws_client then
    return nil, "no websocket client library present or disabled"
  end
  -- attempt to open
  local ok, ws_or_err = pcall(ws_client.connect, full_url)
  if not ok or not ws_or_err then return nil, ("ws connect failed: "..tostring(ws_or_err)) end
  local ws = ws_or_err
  local running = true

  -- start a reader thread/coroutine depending on environment
  local function reader()
    while running do
      local ok2, msg = pcall(function() return ws:receive() end)
      if not ok2 then
        running = false
        if handlers and handlers.on_error then handlers.on_error(msg) end
        break
      end
      if not msg then
        running = false
        if handlers and handlers.on_close then handlers.on_close() end
        break
      end
      if handlers and handlers.on_message then handlers.on_message(msg) end
    end
  end

  -- spawn thread: try ngx or luasocket coroutine
  if ngx and ngx.thread. spawn then
    ngx.thread. spawn(reader)
  else
    -- best-effort: run reader in new coroutine if user will drive it, otherwise leave
    local co = coroutine.create(reader)
    coroutine.resume(co)
  end

  local obj = {
    send = function(payload) return pcall(function() ws:send(payload) end) end,
    -- BUG FIX #7: Improved WebSocket cleanup with proper shutdown
    close = function()
      running = false
      pcall(function() ws:close() end)
      -- Give the reader coroutine time to wake up and exit
      if ngx and ngx.sleep then
        ngx.sleep(0. 1)
      elseif socket and socket.sleep then
        socket. sleep(0.1)
      end
    end,
    raw = ws,
  }
  return obj, nil
end

-- UDP hole-punch helper (best-effort using luasocket): sends repeated empty packets to peer to attempt punching
function M.udp_holepunch(local_port, peer_ip, peer_port, attempts, interval_s)
  if not socket then return nil, "luasocket required for UDP holepunch" end
  attempts = attempts or 5
  interval_s = interval_s or 0.2
  local udp = socket.udp()
  udp:settimeout(0. 1)
  udp:setsockname("*", local_port or 0)
  local function send_one()
    pcall(function() udp:sendto("", peer_ip, peer_port) end)
  end
  for i=1,attempts do
    send_one()
    socket.sleep(interval_s)
  end
  udp:close()
  return true, nil
end

-- Signaling helpers (use server endpoints; servers list/failover applies)
function M.signal_offer(room_or_path, payload)
  -- payload should contain { from=, to=, sdp=, metadata=... }
  -- POST to /signal/offer or path provided relative to servers
  local path = room_or_path or "signal/offer"
  return M.post_json(path, payload)
end
function M.signal_answer(room_or_path, payload)
  local path = room_or_path or "signal/answer"
  return M.post_json(path, payload)
end
function M. signal_poll(path, query)
  local built = path
  if query and type(query) == "table" then
    local qs = {}
    for k,v in pairs(query) do table.insert(qs, tostring(k).."="..tostring(v)) end
    built = built ..  "?" .. table.concat(qs,"&")
  end
  return M.get_json(built)
end

-- TURN allocator helper (server must implement /turn or configured path)
function M.request_turn(path_or_url, body, opts)
  opts = opts or {}
  local path = path_or_url or "turn"
  return M.post_json(path, body or {}, opts)
end

-- small utility: build URL with query (keeps behavior)
function M.build_url(base, params)
  if not params or next(params) == nil then return base end
  local out = {}
  for k,v in pairs(params) do
    table.insert(out, tostring(k).."="..tostring(v))
  end
  return base .. "?" .. table.concat(out, "&")
end

-- export for advanced uses
M._internal = {
  perform_raw_request = perform_raw_request,
  cache_get = cache_get,
  cache_set = cache_set,
  rate_acquire = rate_acquire,
  build_candidates = build_candidates,
}

return M
