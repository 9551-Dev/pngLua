--[[
(c) 2008-2011 David Manura. Licensed under the same terms as Lua (MIT).

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
(end license)
--]]

local ipairs = ipairs
local pairs = pairs
local setmetatable = setmetatable
local math = math
local table_sort = table.sort
local math_max = math.max
local band, lshift, rshift = bit32.band,bit32.lshift,bit32.rshift

local Stream   = {}
local Chunk    = {}
local IHDR     = {}
local IDAT     = {}
local PLTE     = {}
local Pixel    = {}
local ScanLine = {}
local PngImage = {}

local lib = {}

setmetatable(Stream,{__call=function(methods,param)
    local self = {
        position = 1,
        data     = {}
    }

    local str = ""
    if (param.inputF ~= nil) then
        local file = fs.open(param.inputF, "rb")
        str = file.readAll()
        file.close()
    end
    if (param.input ~= nil) then
        str = param.input
    end

    for i=1,#str do
        self.data[i] = str:byte(i, i)
    end

    return setmetatable(self,{__index=methods})
end})

-- constructors
setmetatable(Chunk,{__call=function(methods,stream,chunk)
    local self = {stream=stream,instanceof_chunk=true}

    if chunk and chunk.instanceof_chunk then
        self.length = chunk.length
        self.name   = chunk.name
        self.data   = chunk.data
        self.crc    = chunk.crc
    else
        self.length = stream:readInt()
        self.name   = stream:readChars(4)
        self.data   = stream:readChars(self.length)
        self.crc    = stream:readChars(4)
    end

    return setmetatable(self,{__index=methods})
end})

setmetatable(IHDR,{__call=function(methods,chunk)
    local self = Chunk(chunk.stream,chunk)

    local stream = chunk:getDataStream()

    self.width       = stream:readInt ()
    self.height      = stream:readInt ()
    self.bitDepth    = stream:readByte()
    self.colorType   = stream:readByte()
    self.compression = stream:readByte()
    self.filter      = stream:readByte()
    self.interlace   = stream:readByte()

    return setmetatable(self,{__index=methods})
end})

setmetatable(IDAT,{__call=function(methods,chunk)
    return setmetatable(Chunk(chunk.stream,chunk),{__index=methods})
end})

setmetatable(PLTE,{__call=function(methods,chunk)
    local self  = Chunk(chunk.stream,chunk)
    self.colors = {}

    self.numColors = math.floor(chunk.length/3)

    local stream = chunk:getDataStream()

    for i = 1, self.numColors do
        self.colors[i] = {
            R = stream:readByte(),
            G = stream:readByte(),
            B = stream:readByte(),
        }
    end

    return setmetatable(self,{__index=methods})
end})

local remap_dummy = {}
setmetatable(Pixel,{__call=function(methods,stream,depth,colorType,palette,remap)
    remap = remap or remap_dummy
    local self = {remap=remap}

    local remap_r = remap.r or "r"
    local remap_g = remap.g or "g"
    local remap_b = remap.b or "b"
    local remap_a = remap.a or "a"

    local bps = math.floor(depth/8)
    if colorType == 0 then
        local grey = stream:readInt(bps)
        self[remap_r] = grey/255
        self[remap_g] = grey/255
        self[remap_b] = grey/255
        self[remap_a] = 1
    end
    if colorType == 2 then
        self[remap_r] = stream:readInt(bps)/255
        self[remap_g] = stream:readInt(bps)/255
        self[remap_b] = stream:readInt(bps)/255
        self[remap_a] = 1
    end
    if colorType == 3 then
        local index = stream:readInt(bps)+1
        local color = palette:getColor(index)
        self[remap_r] = color.R/255
        self[remap_g] = color.G/255
        self[remap_b] = color.B/255
        self[remap_a] = 1
    end
    if colorType == 4 then
        local grey = stream:readInt(bps)
        self[remap_r] = grey/255
        self[remap_g] = grey/255
        self[remap_b] = grey/255
        self[remap_a] = stream:readInt(bps)/255
    end
    if colorType == 6 then
        self[remap_r] = stream:readInt(bps)/255
        self[remap_g] = stream:readInt(bps)/255
        self[remap_b] = stream:readInt(bps)/255
        self[remap_a] = stream:readInt(bps)/255
    end

    return setmetatable(self,{__index=methods})
end})

setmetatable(ScanLine,{__call=function(methods,stream,depth,colorType,palette,length,remap)
    local self = {
        pixels 	   = {},
        filterType = 0
    }

    local bpp = math.floor(depth/8) * methods.bitFromColorType(self,colorType)
    local bpl = bpp*length

    self.filterType = stream:readByte()

    stream:seek(-1)
    stream:writeByte(0)

    local startLoc = stream.position
    if self.filterType == 0 then
        for i = 1, length do
            self.pixels[i] = Pixel(stream,depth,colorType,palette,remap)
        end
    end
    if self.filterType == 1 then
        for i = 1, length do
            for _ = 1, bpp do
                local curByte = stream:readByte()
                stream:seek(-(bpp+1))
                local lastByte = 0
                if stream.position >= startLoc then lastByte = stream:readByte() or 0 else stream:readByte() end
                stream:seek(bpp-1)
                stream:writeByte((curByte + lastByte) % 256)
            end
            stream:seek(-bpp)
            self.pixels[i] = Pixel(stream,depth,colorType,palette,remap)
        end
    end
    if self.filterType == 2 then
        for i = 1, length do
            for _ = 1, bpp do
                local curByte = stream:readByte()
                stream:seek(-(bpl+2))
                local lastByte = stream:readByte() or 0
                stream:seek(bpl)
                stream:writeByte((curByte + lastByte) % 256)
            end
            stream:seek(-bpp)
            self.pixels[i] = Pixel(stream,depth,colorType,palette,remap)
        end
    end
    if self.filterType == 3 then
        for i = 1, length do
            for _ = 1, bpp do
                local curByte = stream:readByte()
                stream:seek(-(bpp+1))
                local lastByte = 0
                if stream.position >= startLoc then lastByte = stream:readByte() or 0 else stream:readByte() end
                stream:seek(-(bpl)+bpp-2)
                local priByte = stream:readByte() or 0
                stream:seek(bpl)
                stream:writeByte((curByte + math.floor((lastByte+priByte)/2)) % 256)
            end
            stream:seek(-bpp)
            self.pixels[i] = Pixel(stream,depth,colorType,palette,remap)
        end
    end
    if self.filterType == 4 then
        for i = 1, length do
            for _ = 1, bpp do
                local curByte = stream:readByte()
                stream:seek(-(bpp+1))
                local lastByte = 0
                if stream.position >= startLoc then lastByte = stream:readByte() or 0 else stream:readByte() end
                stream:seek(-(bpl + 2 - bpp))
                local priByte = stream:readByte() or 0
                stream:seek(-(bpp+1))
                local lastPriByte = 0
                if stream.position >= startLoc - (length * bpp + 1) then lastPriByte = stream:readByte() or 0 else stream:readByte() end
                stream:seek(bpl + bpp)
                stream:writeByte((curByte + methods._PaethPredict(self,lastByte,priByte,lastPriByte)) % 256)
            end
            stream:seek(-bpp)
            self.pixels[i] = Pixel(stream,depth,colorType,palette,remap)
        end
    end

    return setmetatable(self,{__index=methods})
end})

setmetatable(PngImage,{__call=function(methods,path,custom_stream,progCallback,data_remap)
    local self = {
        width     = 0,
        height    = 0,
        depth     = 0,
        colorType = 0,
        scanLines = {}
    }

    if data_remap then
        self.remap_r = data_remap.r
        self.remap_g = data_remap.g
        self.remap_b = data_remap.b
        self.remap_a = data_remap.a
    end

    local str = Stream(custom_stream or {inputF = path})
    if str:readChars(8) ~= "\137\080\078\071\013\010\026\010" then error("Not a PNG") end

    local ihdr = {}
    local plte = {}
    local idat = {}
    local num = 1

    while true do
        local ch = Chunk(str)
        if ch.name == "IHDR" then ihdr = IHDR(ch) end
        if ch.name == "PLTE" then plte = PLTE(ch) end
        if ch.name == "IDAT" then idat[num] = IDAT(ch) num = num+1 end
        if ch.name == "IEND" then break end
    end

    self.width     = ihdr.width
    self.height    = ihdr.height
    self.depth     = ihdr.bitDepth
    self.colorType = ihdr.colorType

    local dataStr = ""
    for k,v in pairs(idat) do dataStr = dataStr .. v.data end
    local output = {}
    lib.inflate_zlib{input = dataStr, output = function(byte) output[#output+1] = string.char(byte) end, disable_crc = true}
    local imStr = Stream({input = table.concat(output)})

    for i = 1, self.height do
        self.scanLines[i] = ScanLine(imStr,self.depth,self.colorType,plte,self.width,data_remap)
        if progCallback ~= nil then progCallback(i, self.height) end
    end

    return setmetatable(self,{__index=methods})
end})

-- methods --
function Stream:seek(amount)
    self.position = self.position + amount
end

function Stream:readByte()
    if self.position <= 0 then self:seek(1) return nil end
    local byte = self.data[self.position]
    self:seek(1)
    return byte
end

function Stream:readChar()
    if self.position <= 0 then self:seek(1) return nil end

    local byte = self:readByte()

    if not byte then error("no more bytes to read",3) end

    return string.char(byte)
end

function Stream:readChars(num)
    if self.position <= 0 then self:seek(1) return nil end
    local str = ""
    local i = 1
    while i <= num do
        str = str .. self:readChar()
        i = i + 1
    end
    return str, i-1
end

function Stream:readInt(num)
    if self.position <= 0 then self:seek(1) return nil end

    num = num or 4

    local bytes, count = self:readBytes(num)

    return self:bytesToNum(bytes), count
end

function Stream:readBytes(num)
    if self.position <= 0 then self:seek(1) return nil end

    local tabl = {}
    local i = 1

    while i <= num do
        local curByte = self:readByte()
        if curByte == nil then break end

        tabl[i] = curByte
        i = i + 1
    end
    return tabl, i-1
end

function Stream:bytesToNum(bytes)
    local n = 0

    for _,v in ipairs(bytes) do
        n = n*256 + v
    end

    n = (n > 2147483647) and (n - 4294967296) or n

    return n
end

function Stream:writeByte(byte)
    if self.position <= 0 then self:seek(1) return end
    self.data[self.position] = byte
    self:seek(1)
end

function Chunk:getDataStream()
    return Stream({input = self.data})
end

function PLTE:getColor(index)
    return self.colors[index]
end

function Pixel:format()
    return string.format("R: %d, G: %d, B: %d, A: %d", self.R, self.G, self.B, self.A)
end

function Pixel:unpack()
    local remap_r = self.remap.r or "r"
    local remap_g = self.remap.g or "g"
    local remap_b = self.remap.b or "b"
    local remap_a = self.remap_a or "a"
    return  self[remap_r],
            self[remap_g],
            self[remap_b],
            self[remap_a]
end

function ScanLine:bitFromColorType(colorType)
    if colorType == 0 then return 1 end
    if colorType == 2 then return 3 end
    if colorType == 3 then return 1 end
    if colorType == 4 then return 2 end
    if colorType == 6 then return 4 end
    error("Invalid colortype")
end

function ScanLine:get_pixel(pixel)
    return self.pixels[pixel]
end

function ScanLine:_PaethPredict(a, b, c)
    local p = a + b - c
    local varA = math.abs(p - a)
    local varB = math.abs(p - b)
    local varC = math.abs(p - c)
    if varA <= varB and varA <= varC then return a end
    if varB <= varC then return b end
    return c
end

function PngImage:get_pixel(x, y)
    local pixel = self.scanLines[y].pixels[x]
    return pixel
end

local function make_outstate(outbs)
    local outstate = {}
    outstate.outbs = outbs
    outstate.window = {}
    outstate.window_pos = 1
    return outstate
end

local function output(outstate, byte)
    local window_pos = outstate.window_pos
    outstate.outbs(byte)
    outstate.window[window_pos] = byte
    outstate.window_pos = window_pos % 32768 + 1
end

local function memoize(f)
    local mt = {}
    local t = setmetatable({}, mt)
    function mt:__index(k)
        local v = f(k)
        t[k] = v
        return v
    end
    return t
end

local pow2 = memoize(function(n) return 2^n end)

local is_bitstream = setmetatable({}, {__mode='k'})

local function bytestream_from_string(s)
    local i = 1
    local o = {}

    function o:read()
        local by
        if i <= #s then
            by = s:byte(i)
            i = i + 1
        end
        return by
    end

    return o
end

local function bitstream_from_bytestream(bys)
    local buf_byte = 0
    local buf_nbit = 0
    local o = {}

    function o:nbits_left_in_byte()
        return buf_nbit
    end

    function o:read(nbits)
        nbits = nbits or 1
        while buf_nbit < nbits do
            local byte = bys:read()
            if not byte then return end
            buf_byte = buf_byte + lshift(byte, buf_nbit)
            buf_nbit = buf_nbit + 8
        end
        local bits
        if nbits == 0 then
            bits = 0
        elseif nbits == 32 then
            bits = buf_byte
            buf_byte = 0
        else
            bits = band(buf_byte, rshift(0xffffffff, 32 - nbits))
            buf_byte = rshift(buf_byte, nbits)
        end
        buf_nbit = buf_nbit - nbits
        return bits
    end

    is_bitstream[o] = true

    return o
end

local function HuffmanTable(init, is_full)
    local t = {}
    if is_full then
        for val,nbits in pairs(init) do
            if nbits ~= 0 then
                t[#t+1] = {val=val, nbits=nbits}
            end
        end
    else
        for i=1,#init-2,2 do
            local firstval, nbits, nextval = init[i], init[i+1], init[i+2]
            if nbits ~= 0 then
                for val=firstval,nextval-1 do
                t[#t+1] = {val=val, nbits=nbits}
                end
            end
        end
    end
    table_sort(t, function(a,b)
        return a.nbits == b.nbits and a.val < b.val or a.nbits < b.nbits
    end)

    local code = 1
    local nbits = 0
    for i,s in ipairs(t) do
        if s.nbits ~= nbits then
            code = code * pow2[s.nbits - nbits]
            nbits = s.nbits
        end
        s.code = code
        code = code + 1
    end

    local minbits = math.huge
    local look = {}
    for i,s in ipairs(t) do
        minbits = math.min(minbits, s.nbits)
        look[s.code] = s.val
    end

    local function msb(bits,nbits)
        local res = 0
        for i=1,nbits do
            res = lshift(res, 1) + band(bits, 1)
            bits = rshift(bits, 1)
        end
        return res
    end

    local tfirstcode = memoize(function(bits) return pow2[minbits] + msb(bits, minbits) end)

    function t:read(bs)
        local code = 1
        local nbits = 0
        while 1 do
            if nbits == 0 then
                code = tfirstcode[bs:read(minbits)]
                nbits = nbits + minbits
            else
                local b = bs:read()
                nbits = nbits + 1
                code = code * 2 + b
            end
            local val = look[code]
            if val then
                return val
            end
        end
    end

    return t
end

local function parse_huffmantables(bs)
    local hlit  = bs:read(5)
    local hdist = bs:read(5)
    local hclen = bs:read(4)

    local ncodelen_codes = hclen + 4
    local codelen_init = {}
    local codelen_vals = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
    for i=1,ncodelen_codes do
        local nbits = bs:read(3)
        local val = codelen_vals[i]
        codelen_init[val] = nbits
    end
    local codelentable = HuffmanTable(codelen_init, true)

    local function decode(ncodes)
        local init = {}
        local nbits
        local val = 0
        while val < ncodes do
            local codelen = codelentable:read(bs)
            local nrepeat
            if codelen <= 15 then
                nrepeat = 1
                nbits = codelen
            elseif codelen == 16 then
                nrepeat = 3 + bs:read(2)
            elseif codelen == 17 then
                nrepeat = 3 + bs:read(3)
                nbits = 0
            elseif codelen == 18 then
                nrepeat = 11 + bs:read(7)
                nbits = 0
            end
            for _=1,nrepeat do
                init[val] = nbits
                val = val + 1
            end
        end
        local huffmantable = HuffmanTable(init, true)
        return huffmantable
    end

    local nlit_codes = hlit + 257
    local ndist_codes = hdist + 1

    local littable = decode(nlit_codes)
    local disttable = decode(ndist_codes)

    return littable, disttable
end

local tdecode_len_base
local tdecode_len_nextrabits
local tdecode_dist_base
local tdecode_dist_nextrabits
local function parse_compressed_item(bs, outstate, littable, disttable)
    local val = littable:read(bs)
    if val < 256 then
        output(outstate, val)
    elseif val == 256 then
        return true
    else
        if not tdecode_len_base then
            local t = {[257]=3}
            local skip = 1
            for i=258,285,4 do
                for j=i,i+3 do t[j] = t[j-1] + skip end
                if i ~= 258 then skip = skip * 2 end
            end
            t[285] = 258
            tdecode_len_base = t
        end
        if not tdecode_len_nextrabits then
            local t = {}

            for i=257,285 do
                local j = math_max(i - 261, 0)
                t[i] = rshift(j, 2)
            end

            t[285] = 0
            tdecode_len_nextrabits = t
        end

        local len_base = tdecode_len_base[val]
        local nextrabits = tdecode_len_nextrabits[val]
        local extrabits = bs:read(nextrabits)
        local len = len_base + extrabits

        if not tdecode_dist_base then
            local t = {[0]=1}
            local skip = 1
            for i=1,29,2 do
                for j=i,i+1 do t[j] = t[j-1] + skip end
                if i ~= 1 then skip = skip * 2 end
            end
            tdecode_dist_base = t
        end
        if not tdecode_dist_nextrabits then
            local t = {}
            for i=0,29 do
                local j = math_max(i - 2, 0)
                t[i] = rshift(j, 1)
            end

            tdecode_dist_nextrabits = t
        end
        local dist_val = disttable:read(bs)
        local dist_base = tdecode_dist_base[dist_val]
        local dist_nextrabits = tdecode_dist_nextrabits[dist_val]
        local dist_extrabits = bs:read(dist_nextrabits)
        local dist = dist_base + dist_extrabits
        for i=1,len do
            local pos = (outstate.window_pos - 1 - dist) % 32768 + 1
            output(outstate,outstate.window[pos])
        end
    end
    return false
end

local function parse_block(bs, outstate)
    local bfinal = bs:read(1)
    local btype  = bs:read(2)

    local BTYPE_NO_COMPRESSION = 0
    local BTYPE_FIXED_HUFFMAN = 1
    local BTYPE_DYNAMIC_HUFFMAN = 2

    if btype == BTYPE_NO_COMPRESSION then
        bs:read(bs:nbits_left_in_byte())
        local len = bs:read(16)
        bs:read(16)

        for _=1,len do
            output(outstate, bs:read(8))
        end
    elseif btype == BTYPE_FIXED_HUFFMAN or btype == BTYPE_DYNAMIC_HUFFMAN then
        local littable, disttable
        if btype == BTYPE_DYNAMIC_HUFFMAN then
            littable, disttable = parse_huffmantables(bs)
        else
            littable  = HuffmanTable {0,8, 144,9, 256,7, 280,8, 288,nil}
            disttable = HuffmanTable {0,5, 32,nil}
        end

        repeat
            local is_done = parse_compressed_item(bs, outstate, littable, disttable)
        until is_done
    end

    return bfinal ~= 0
end

local function inflate(t)
    local bs = is_bitstream[t.input] and t.input or bitstream_from_bytestream(bytestream_from_string(t.input))
    local outstate = make_outstate(t.output)

    repeat
        local is_final = parse_block(bs, outstate)
    until is_final
end

local function adler32(byte, crc)
    local s1 = crc % 65536
    local s2 = (crc - s1) / 65536
    s1 = (s1 + byte) % 65521
    s2 = (s2 + s1) % 65521
    return s2*65536 + s1
end

function lib.inflate_zlib(t)
    local bs = bitstream_from_bytestream(bytestream_from_string(t.input))
    local disable_crc = t.disable_crc
    if disable_crc == nil then disable_crc = false end

    bs:read(13)
    if bs:read(1) == 1 then bs:read(32) end
    bs:read(2)

    local data_adler32 = 1

    inflate{input=bs, output=
        disable_crc and t.output or function(byte)
            data_adler32 = adler32(byte, data_adler32)
            t.output(byte)
        end
    }

    bs:read(bs:nbits_left_in_byte())
end

return PngImage
