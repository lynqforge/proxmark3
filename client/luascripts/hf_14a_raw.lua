--[[
    hf_14a_raw.lua
    -----------------
    This script provides a very small wrapper around the "raw" ISO14443A
    reader functionality of the Proxmark3 client.  It can be used to send
    arbitrary APDU frames to a tag and print the responses.  The script is
    particularly handy for quick tests or when prototyping commands that are
    not yet supported by the standard client commands.

    It relies on a few helper modules that ship with the Proxmark3 client:
      * commands   - definitions of command numbers and helpers for constructing
                     USB frames.
      * getopt     - simple command line option parser used by many scripts.
      * read14a    - helper library for basic ISO14443A card interaction
                     (connecting, disconnecting, etc.).
      * ansicolors - for colored output in the help text.

    Usage examples and option descriptions can be displayed by running the
    script with no parameters.  See the long comment at the top of this file for
    more information on typical workflows.
]]

local cmds       = require('commands')
local getopt     = require('getopt')
local lib14a     = require('read14a')
local ansicolors = require('ansicolors')

copyright = ''
author = "Martin Holst Swende"
version = 'v1.0.2'
-- Short description shown in the client when listing available scripts
desc = [[
Send arbitrary ISO14443A frames to a tag and optionally display the raw
response.  Useful for low level experimentation or when building new
functionality.
]]
example = [[
    # 1. Connect and don't disconnect
    script run hf_14a_raw -k

    # 2. Send mf auth, read response (nonce)
    script run hf_14a_raw -o -x 6000F57b -k

    # 3. disconnect
    script run hf_14a_raw -o

    # All three steps in one go:
    script run hf_14a_raw -x 6000F57b
]]
usage = [[
script run hf_14a_raw -x 6000F57b
]]
arguments = [[
    -o              do not connect - use this only if you previously used -k to stay connected
    -r              do not read response
    -c              calculate and append CRC
    -k              stay connected - don't inactivate the field
    -x <payload>    Data to send (NO SPACES!)
    -d              Debug flag
    -t              Topaz mode
    -3              ISO14443-4 (use RATS)
]]

--[[

This script communicates with
/armsrc/iso14443a.c, specifically ReaderIso14443a() at around line 1779 and onwards.

Check there for details about data format and how commands are interpreted on the
device-side.
]]

-- Some globals
local DEBUG = false -- the debug flag

-------------------------------
-- Some utilities
-------------------------------

---
-- A debug printout-function
local function dbg(args)
    if not DEBUG then return end
    if type(args) == 'table' then
        local i = 1
        while args[i] do
            dbg(args[i])
            i = i+1
        end
    else
        print('###', args)
    end
end
---
-- This is only meant to be used when errors occur
local function oops(err)
    print('ERROR:', err)
    core.clearCommandBuffer()
    return nil, err
end
---
--- Print a nicely formatted usage message describing all available options.
local function help()
    print(copyright)
    print(author)
    print(version)
    print(desc)
    print(ansicolors.cyan..'Usage'..ansicolors.reset)
    print(usage)
    print(ansicolors.cyan..'Arguments'..ansicolors.reset)
    print(arguments)
    print(ansicolors.cyan..'Example usage'..ansicolors.reset)
    print(example)
end
---
-- Entry point when invoked via ``script run hf_14a_raw``.
-- Parses command line flags, manages the card connection and sends the
-- optional raw frame to the tag.
--
-- @param args  String containing the argument list.
function main(args)

    if args == nil or #args == 0 then return help() end

    local ignore_response = false
    local append_crc = false
    local stayconnected = false
    local payload = nil
    local doconnect = true
    local topaz_mode = false
    local no_rats = false

    -- Read the parameters
    for o, a in getopt.getopt(args, 'orcpx:dt3') do
        if o == 'o' then doconnect = false end
        if o == 'r' then ignore_response = true end
        if o == 'c' then append_crc = true end
        if o == 'p' then stayconnected = true end
        if o == 'x' then payload = a end
        if o == 'd' then DEBUG = true end
        if o == 't' then topaz_mode = true end
        if o == '3' then no_rats = true end
    end

    -- First of all, connect
    if doconnect then
        dbg("doconnect")

        info, err = lib14a.read(true, no_rats)
        if err then
            lib14a.disconnect()
            return oops(err)
        end
        print(('Connected to card, uid = %s'):format(info.uid))
    end

    -- The actual raw payload, if any
    if payload then
        res, err = sendRaw(payload,{ignore_response = ignore_response, topaz_mode = topaz_mode, append_crc = append_crc})
        if err then
            lib14a.disconnect()
            return oops(err)
        end

        -- Unless the user explicitly asked to ignore it, display the
        -- response returned from the card.  Note the misspelled variable
        -- name here is historical; keep the behaviour consistent by
        -- checking the correctly named one.
        if not ignore_response then
            -- Display the returned data
            showdata(res)
        end
    end
    -- And, perhaps disconnect?
    if not stayconnected then
        lib14a.disconnect()
    end
end

--- Picks out and displays the data read from a tag
-- Specifically, takes a usb packet, converts to a Command
-- (as in commands.lua), takes the data-array and
---
-- Parse a raw response USB packet from the Proxmark3 firmware and print
-- the resulting data bytes.
--
-- The firmware encodes the returned bytes as an ASCII hex string in the
-- ``data`` field of the response.  ``arg1`` contains the length of that
-- buffer.  This helper extracts exactly ``arg1`` bytes and prints them
-- prefixed with ``<<`` so that the output resembles the normal client
-- command output.
--
-- @param usbpacket  Raw USB packet returned from ``sendMIX``.
function showdata(usbpacket)
    local cmd_response = Command.parse(usbpacket)
    local len = tonumber(cmd_response.arg1) *2
    --print("data length:",len)
    local data = string.sub(tostring(cmd_response.data), 0, len);
    print("<< ",data)
end

---
-- Send a raw ISO14443A frame to the tag.
--
-- @param rawdata   Hex string representing the bytes to transmit.
-- @param options   Table of flags:
--                   * ignore_response - if true, do not wait for a reply.
--                   * topaz_mode      - send using Topaz modulation.
--                   * append_crc      - ask firmware to append CRC.
function sendRaw(rawdata, options)
    -- Echo the frame so the user can see exactly what is being sent
    print('>> ', rawdata)

    -- Build the flag bitmask used by the firmware when interpreting the frame.
    -- We always request RAW mode and we do not want the firmware to
    -- automatically deactivate the RF field between commands.
    local flags = lib14a.ISO14A_COMMAND.ISO14A_NO_DISCONNECT +
                  lib14a.ISO14A_COMMAND.ISO14A_RAW

    -- Optional behaviour controlled by command line flags
    if options.topaz_mode then
        -- Switch the reader to Topaz modulation when communicating
        flags = flags + lib14a.ISO14A_COMMAND.ISO14A_TOPAZMODE
    end
    if options.append_crc then
        -- Let the firmware automatically calculate and append the CRC
        flags = flags + lib14a.ISO14A_COMMAND.ISO14A_APPEND_CRC
    end

    -- Construct the USB command.  ``arg2`` holds the number of bytes in the
    -- frame (the firmware expects a byte count, not an ASCII string length).
    local command = Command:newMIX{
        cmd  = cmds.CMD_HF_ISO14443A_READER,
        arg1 = flags,
        arg2 = string.len(rawdata) / 2,
        data = rawdata
    }
    -- ``sendMIX`` transmits the command and optionally waits for a response.
    return command:sendMIX(options.ignore_response)
end


-------------------------
-- Testing
-------------------------
function selftest()
    DEBUG = true
    dbg('Performing test')
    main()
    main('-k')
    main(' -o -x 6000F57b -k')
    main('-o')
    main('-x 6000F57b')
    dbg('Tests done')
end
-- Flip the switch here to perform a sanity check.
-- It read a nonce in two different ways, as specified in the usage-section
if '--test'==args then
    selftest()
else
    -- Call the main
    main(args)
end
