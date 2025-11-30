 -- Universal, environment-adaptive HTTP/REST client for Lua
-- Usage: local rest = require("universal_rest"); rest.init(opts); rest:get_json(url, opts)

local socket_ok, http = pcall(require, "socket.http")
local ltn12_ok, ltn12 = pcall(require, "ltn12")
local json_ok, json = pcall(require, "dkjson") -- optional; fallback to simplistic encoder/decoder below
local has_luasocket = socket_ok and ltn12_ok

local ok_resty_http, resty_http = pcall(require, "resty.http")
local ngx_available = (type(ngx) == "table" and ok_resty_http)

-- simple JSON fallback (very small; for production prefer dkjson/cjson)
local function simple_encode(t)
  if type(t) ~= "table" then return tostring(t) end
  local parts = {}
  for k,v in pairs(t) do
    local key = tostring(k):gsub('"','\\"')
    local val = type(v) == "string" and ("\"" .. v:gsub('"','\\"') .. "\"")
              or (type(v) == "number" and tostring(v))
              or (type(v) == "boolean" and tostring(v))
              or (type(v) == "table" and simple_encode(v))
              or "\"\""
    parts[#parts+1] = '"'..key..'":'..val
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function simple_decode(_) error("No JSON decoder available; install dkjson or cjson") end

local JSON = (json_ok and json) and { encode = function(t) return json.encode(t) end, decode = function(s) return json.decode(s) end }
          or { encode = simple_encode, decode = simple_decode }

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
  logger = function(...) io.write(table.concat({...}," ").."\n") end,
  rate_limits = {},         -- host -> { capacity=, refill_per_sec= }
  cache_enabled = true,
  cache_max_items = 1000,
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
  if not M.config.cache_enabled then return end
  if ttl and ttl <= 0 then return end
  if #cache_index > M.config.cache_max_items then
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
  local cfg = M.config.rate_limits[host]
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
    st.tokens = st.tokens - (cost or 1)
    return true
  end
  return false
end

-- backoff function
local function backoff(attempt)
  local base = M.config.backoff_base
  local factor = M.config.backoff_factor
  local jitter = M.config.jitter
  local ms = base * (factor ^ (attempt - 1))
  if jitter then
    local j = math.random(0, base)
    ms = ms + j
  end
  return ms / 1000 -- seconds
end

-- choose adapter and perform a raw request (returns status, body, headers, err)
local function perform_raw_request(method, url, headers, body, timeout_ms)
  timeout_ms = timeout_ms or M.config.timeout
  -- OpenResty (lua-resty-http) path
  if ngx_available then
    local httpc = resty_http.new()
    if timeout_ms then httpc:set_timeout(timeout_ms) end
    local parsed = require("socket.url").parse(url)
    local host = parsed.host
    local port = tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80)
    local ok, err = httpc:connect(host, port)
    if not ok then return nil, nil, nil, "connect error: "..tostring(err) end
    if parsed.scheme == "https" then
      local _, ssl_err = httpc:ssl_handshake(nil, host, false)
      if ssl_err then return nil, nil, nil, "ssl handshake error: "..tostring(ssl_err) end
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
        if recv_err then return res.status, nil, res.headers, "read body error: "..tostring(recv_err) end
        break
      end
      table.insert(chunks, chunk)
      if #chunk == 0 then break end
    end
    local body_str = table.concat(chunks)
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
      timeout = timeout_ms / 1000, -- socket.http uses seconds in create? Not standard across versions
    }
    local status = c -- c is status code or nil
    local headers_out = h or {}
    local body_str = table.concat(resp_body)
    return status, body_str, headers_out, (r and nil) or "socket error"
  end

  return nil, nil, nil, "no supported HTTP adapter (install luasocket or lua-resty-http)"
end

-- high-level request with retries, rate-limit, caching
local function request(method, url, opts)
  opts = opts or {}
  local headers = opts.headers or {}
  headers["User-Agent"] = headers["User-Agent"] or M.config.user_agent
  if opts.json and opts.body and type(opts.body) == "table" then
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    opts.body = M.config.json.encode(opts.body)
  end
  if opts.bearer then headers["Authorization"] = "Bearer " .. opts.bearer end
  if opts.basic then
    local user, pass = opts.basic.user or "", opts.basic.pass or ""
    local b = (user .. ":" .. pass)
    local enc = (mime and mime.b64) and mime.b64(b) or (require("mime") and require("mime").b64(b) or nil)
    if enc then headers["Authorization"] = "Basic " .. enc end
  end

  local host = url:match("^https?://([^/]+)") or "default"
  local cache_key = method .. "|" .. url .. "|" .. (opts.body or "")
  if method == "GET" and opts.cache_ttl then
    local cached = cache_get(cache_key)
    if cached then return 200, cached, { from_cache = true } end
  end

  local attempts = (opts.retries ~= nil) and opts.retries or M.config.retries
  local attempt = 0
  while attempt <= attempts do
    attempt = attempt + 1
    if not rate_acquire(host, opts.rate_cost or 1) then
      -- simple wait if rate limit prevents immediate send
      M.config.logger("rate_limited", host)
      if attempt <= attempts then
        local wait = backoff(attempt)
        if ngx then ngx.sleep(wait) else os.execute("sleep " .. tonumber(wait)) end
        goto continue
      else
        return nil, nil, nil, "rate_limited"
      end
    end

    local status, body, resp_headers, err = perform_raw_request(method, url, headers, opts.body, opts.timeout_ms)
    if err then
      M.config.logger("request_error", method, url, err, "attempt", attempt)
    else
      -- treat 2xx as success
      local status_num = tonumber(status) or 0
      if status_num >= 200 and status_num < 300 then
        if method == "GET" and opts.cache_ttl then cache_set(cache_key, body, opts.cache_ttl) end
        return status_num, body, resp_headers, nil
      end
      -- check for unrecoverable status (4xx except 429)
      if status_num >= 400 and status_num < 500 and status_num ~= 429 then
        return status_num, body, resp_headers, nil
      end
      -- else treat as retryable
      M.config.logger("http_status", status_num, "attempt", attempt)
    end

    if attempt > attempts then
      return nil, body, resp_headers, err or ("max attempts reached, last status "..tostring(status))
    end

    local wait = backoff(attempt)
    if ngx then ngx.sleep(wait) else os.execute("sleep " .. tonumber(wait)) end
    ::continue::
  end
end

-- convenience helpers
function M.init(opts)
  for k,v in pairs(opts or {}) do M.config[k] = v end
  math.randomseed(os.time() % 65536)
end

function M.request(method, url, opts)
  return request(method:upper(), url, opts)
end

function M.get(url, opts) return M.request("GET", url, opts) end
function M.post(url, opts) return M.request("POST", url, opts) end
function M.put(url, opts) return M.request("PUT", url, opts) end
function M.delete(url, opts) return M.request("DELETE", url, opts) end

-- JSON helpers
function M.get_json(url, opts)
  opts = opts or {}
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.get(url, opts)
  if not status then return nil, nil, err end
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
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: "..tostring(decoded) end
  return status, decoded, nil
end

-- Batch requests (parallel attempt if environment supports coroutines or ngx)
function M.batch(requests, opts)
  -- requests: { { method="GET", url="...", opts={} }, ... }
  local results = {}
  -- if ngx, use cosockets / non-blocking; here we simply run sequentially for simplicity
  for i, r in ipairs(requests) do
    local st, body, hdrs, err = M.request(r.method or "GET", r.url, r.opts or {})
    results[i] = { status = st, body = body, headers = hdrs, err = err }
  end
  return results
end

-- small utility: build URL with query
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
}

return M
