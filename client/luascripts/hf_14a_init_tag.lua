-- Script to initialize a tag with a predefined sequence of APDUs
local cmds = require('commands')
local getopt = require('getopt')
local lib14a = require('read14a')
local ansicolors = require('ansicolors')

copyright = ''
author = 'Auto generated'
version = 'v0.1'
desc = [[
Send a fixed sequence of APDU commands to initialize a tag.
Each command's response is checked against the expected value.
]]
usage = [[
script run hf_14a_init_tag [-d]
]]
arguments = [[
    -d  Enable debug output
]]

local DEBUG = false
local function dbg(msg)
    if DEBUG then print('###', msg) end
end

local function oops(err)
    print('ERROR:', err)
    core.clearCommandBuffer()
    return nil, err
end

local function help()
    print(copyright)
    print(author)
    print(version)
    print(desc)
    print(ansicolors.cyan..'Usage'..ansicolors.reset)
    print(usage)
    print(ansicolors.cyan..'Arguments'..ansicolors.reset)
    print(arguments)
end

-- Helper to send an APDU and return response data as hex string
local function sendAPDU(apdu)
    local flags = lib14a.ISO14A_COMMAND.ISO14A_NO_DISCONNECT + lib14a.ISO14A_COMMAND.ISO14A_APDU
    local c = Command:newMIX{cmd = cmds.CMD_HF_ISO14443A_READER,
                              arg1 = flags,
                              arg2 = #apdu / 2,
                              arg3 = 0,
                              data = apdu}
    local pkt, err = c:sendMIX(false)
    if not pkt then return nil, err end
    local rsp = Command.parse(pkt)
    local len = tonumber(rsp.arg1) * 2
    return rsp.data:sub(1, len)
end

-- parse big sequence
local sequence_data = [=====[
// unlock chip, install patch, preconfigure chip
a0 20 01 00 38 85 cb 52 40 dc ad 85 8e 58 2f 66 e1 ee b4 43 6c ff 4d 33 9f 7b bd dc 1f f0 c2 ba 09 17 0e c5 38 a5 ca c3 db 40 e6 5c f1 33 b9 d7 64 22 50 b7 ca 6e b8 6c 6b a8 76 ce 71
// => 90 00
a0 22 01 01 08 ff 4d 33 9f 7b bd dc 1f
// => 90 00
]=====]

-- TODO: Add the remaining initialization commands here
local sequence = {}
for line in sequence_data:gmatch("[^\n]+") do
    local cmd, expected = line:match("^%s*([%x%s]+)%s*//%s*=>%s*([%x%s]+)%s*$")
    if cmd then
        table.insert(sequence, {cmd = cmd:gsub("%s+", ""), expected = expected:gsub("%s+", "")})
    end
end

-- Main function
function main(args)
    for o in getopt.getopt(args, 'd') do
        if o == 'd' then DEBUG = true end
    end

    if #sequence == 0 then
        print('No commands loaded')
        return
    end

    local info, err = lib14a.read(true, true)
    if err then return oops(err) end
    print(('Connected to card, uid = %s'):format(info.uid))

    local errors = {}
    for i, entry in ipairs(sequence) do
        dbg('CMD '..i..': '..entry.cmd)
        local resp, err = sendAPDU(entry.cmd)
        if not resp then
            table.insert(errors, {i, 'communication error'})
            dbg(err)
        else
            dbg('RSP '..resp)
            if resp:lower() ~= entry.expected:lower() then
                table.insert(errors, {i, resp})
                print(string.format('Mismatch at step %d: expected %s got %s', i, entry.expected, resp))
            end
        end
    end

    lib14a.disconnect()

    if #errors == 0 then
        print('Initialization sequence completed successfully')
    else
        print(('Initialization completed with %d errors'):format(#errors))
    end
end

if '--test' == args then
    main('-d')
else
    main(args)
end
