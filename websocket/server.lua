local class = require "class"
local skynet = require "skynet"

local crypt = require "skynet.crypt"
local sha1 = crypt.sha1
local base64encode = crypt.base64encode

local socket = require "skynet.socket"
local sock_readline = socket.readline
local sock_send = socket.write
local sock_close = socket.close

local wbproto = require "websocket.protocol"
local _recv_frame = wbproto.recv_frame
local _send_frame = wbproto.send_frame

local type = type
local char = string.char
local pcall = pcall
local tostring = tostring
local tonumber = tonumber
local match = string.match
local lower = string.lower
local concat = table.concat
local co_self = coroutine.running

local HTTP_CODE = {
  [101] = "HTTP/1.1 101 Switching Protocol",
  [400] = "HTTP/1.1 400 Bad Request",
  [401] = "HTTP/1.1 401 Unauthorized",
  [403] = "HTTP/1.1 403 Forbidden",
  [405] = "HTTP/1.1 405 Method Not Allowed",
  [505] = "HTTP/1.1 505 HTTP Version Not Supported",
}

local function NORMAL_RESPONSE (headers, sec_key)
  local response = {
    HTTP_CODE[101],
    "Connection: Upgrade",
    "Upgrade: websocket",
    "Sec-WebSocket-Accept: " .. base64encode(sha1(sec_key..'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')),
  }
  local protocol = headers['Sec-Websocket-Protocol']
  if protocol then -- 仅支持协议回传
    response[#response+1] = "Sec-Websocket-Protocol: ".. (protocol ~= '' and protocol or "chat")
  end
  response[#response+1] = "\r\n"
  return concat(response, "\r\n")
end

local function ERROR_RESPONSE (code)
  return concat({
    HTTP_CODE[code],
    "Date: ", os.date("Date: %a, %d %b %Y %X GMT"),
    "Connection: close",
    "Content-length: 0",
    "Server: Skynet/WS 0.1",
    "\r\n",
  }, '\r\n')
end

-- 头部信息检查
local function challenge (fd, headers)
  if not headers['Upgrade'] or lower(headers['Upgrade']) ~= 'websocket' then
    sock_send(fd, ERROR_RESPONSE(401))
    return nil, "1. 不受支持的升级协议."
  end
  if headers['Sec-WebSocket-Version'] ~= '13' then
    sock_send(fd, ERROR_RESPONSE(403))
    return nil, "2. 不受支持的协议版本."
  end
  local sec_key = headers['Sec-WebSocket-Key']
  if not sec_key or sec_key == '' then
    sock_send(fd, ERROR_RESPONSE(505))
    return nil, "3. 无效的Sec-WebSocket-Key."
  end
  sock_send(fd, NORMAL_RESPONSE(headers, sec_key))
  return true
end

-- 握手
local function do_handshak (self)
  local fd, auth = self.fd, false
  skynet.fork(function (...)
    skynet.sleep(self.timeout or 3 * 100)
    if not auth then
      self.fd = nil
      return sock_close(fd)
    end
  end)
  local protocol = sock_readline(fd, '\r\n')
  if not protocol then
    return nil, "客户端断开了连接: data is nil."
  end
  local method, path, version = match(protocol, '(%a+) (.+) HTTP/([%d%.]+)')
  if not method or not path or not version then
    sock_send(fd, ERROR_RESPONSE(400))
    return nil, "1. 错误的HTTP Protocol Path 或者 methond."
  end
  if method ~= "GET" or (self.path and self.path ~= path) or tonumber(version) ~= 1.1 then
    sock_send(fd, ERROR_RESPONSE(405))
    return nil, "2. 不支持的HTTP Protocol 版本."
  end
  local headers = {}
  while 1 do
    local data = sock_readline(fd, '\r\n')
    if not data then
      return nil, "2. 客户端断开了连接: data is nil."
    end
    if data == '' then
      break
    end
    local key, value = match(data, "(.+): (.+)")
    if key and value then
      headers[key] = value
    end
  end
  local ok, err = challenge(fd, headers)
  if not ok then
    return nil, err
  end
  auth = true
  return ok
end

local websocket = class("websocket-server")

function websocket:ctor(opt)
  self.fd = opt.fd
  self.cls = opt.cls
end

-- 超时时间
function websocket:set_timeout (timeout)
  if type(timeout) == 'number' and timeout > 0 then
    self.timeout = timeout
  end
  return self
end

-- Websocket Server 事件循环
function websocket:start()
  socket.start(self.fd)
  local ok, msg = do_handshak(self)
  if not ok then
    skynet.error(msg)
    return self:close()
  end
  local max_payload_len, send_masked
  local cls = self.cls:new {
    ws = {
      send = function (ws, data, binary) -- 向客户端发送text/binary消息
        if ws.closed then
          return
        end
        if type(data) == 'string' and data ~= '' then
          return _send_frame(self.fd, true, binary and 0x2 or 0x1, data, max_payload_len, send_masked)
        end
      end,
      close = function (ws, data) -- 向客户端发送close消息
        if ws.closed then
          return
        end
        ws.closed = true
        return _send_frame(self.fd, true, 0x8, char(((1000 >> 8) & 0xff), (1000 & 0xff))..(type(data) ~= 'string' and '' or data), max_payload_len, send_masked)
      end,
    }
  }
  self.cls = nil
  send_masked = cls.send_masked
  max_payload_len = cls.max_payload_len or 65535
  local on_open = assert(type(cls.on_open) == 'function' and cls.on_open, "请为WebSocket对象注册on_open方法")
  local on_error = assert(type(cls.on_error) == 'function' and cls.on_error, "请为WebSocket对象注册on_error方法")
  local on_close = assert(type(cls.on_close) == 'function' and cls.on_close, "请为WebSocket对象注册on_close方法")
  local on_message = assert(type(cls.on_message) == 'function' and cls.on_message, "请为WebSocket对象注册on_message方法")
  local ok, msg = pcall(on_open, cls)
  if not ok then
    skynet.error(msg)
    return self:close()
  end
  while 1 do
    local data, typ, msg = _recv_frame(self.fd, max_payload_len, send_masked)
    if (not data and not typ) or typ == 'close' then
      cls.ws.closed = true
      if err then
        local ok, err = pcall(on_error, cls, msg)
        if not ok then
          skynet.error(err)
        end
      end
      local ok, err = pcall(on_close, cls, msg)
      if not ok then
        skynet.error(err)
      end
      break
    end
    if typ == "text" or typ == 'binary' then
      skynet.fork(on_message, cls, data, typ)
    end
    if typ == "ping" then
      skynet.fork(function (...)
        return _send_frame(self.fd, true, 0xA, data or '', max_payload_len, send_masked)
      end)
    end
  end
  return self:close()
end

-- 关闭
function websocket:close ()
  if self.fd then
    sock_close(self.fd)
    self.fd = nil
  end
end

return websocket
