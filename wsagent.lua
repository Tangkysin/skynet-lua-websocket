local skynet = require "skynet"
local socket = require "skynet.socket"
local wsserver = require "websocket.server"
local class = require "class"

local CMD = {}
local client_fd
local WATCHDOG
local WSS  -- websocket server
local ws_instance
local ws = class("ws")

function ws:ctor(opt)
    self.ws = opt.ws
    ws_instance = opt.ws -- websocket对象
    self.headers = opt.headers -- http headers
    self.send_masked = false -- 掩码(默认为false, 不建议修改或者使用)
    self.max_payload_len = 65535 -- 最大有效载荷长度(默认为65535, 不建议修改或者使用)
end

function ws:on_open()
    self.state = true
    self.count = 1
    skynet.error("websocket客户端" .. client_fd .. "已连接，开始接收数据")
    skynet.fork(
        function()
            while true do
                send("heartbeat")
                skynet.sleep(500)
            end
        end
    )
end

function ws:on_message(msg, msg_type)
    -- 客户端消息
    skynet.error("客户端" .. client_fd .. "发送消息:", msg, msg_type)

end

function ws:on_error(msg)
    -- 错误消息
    skynet.error("错误的消息:", msg)
end

function ws:on_close(msg)
    -- 清理数据
    skynet.error("websocket客户端" .. client_fd .. "断开了连接:", msg)
end

function send(data)
    -- body
    ws_instance.send(ws_instance, data)
end

-- 服务器踢人下线
function kick()
    skynet.call(WATCHDOG, "lua", "kick", client_fd)
end

function CMD.start(conf)
    -- 连接接入
    local fd = conf.client
    local gate = conf.gate
    WATCHDOG = conf.watchdog
    client_fd = fd
    skynet.error("开始接管watchDog" .. client_fd .. "连接")
    WSS =
        wsserver:new {
        fd = client_fd,
        cls = ws,
        nodelay = true
    }
    WSS:start()
    skynet.call(gate, "lua", "forward", fd)
end

function CMD.disconnect()
    -- todo: do something before exit
    skynet.error("watchDog" .. client_fd .. "连接断开")
    skynet.sleep(100)
    skynet.exit()
end

skynet.start(
    function()
        skynet.dispatch(
            "lua",
            function(_, _, command, ...)
                skynet.trace()
                local f = CMD[command]
                skynet.retpack(f(...))
            end
        )
    end
)
