local component = require("component")
local term = require("term")
local gtm = component.gt_machine
local gpu = component.gpu
--#region RingBuffer
RingBuffer = {}
RingBuffer.__index = RingBuffer
function RingBuffer.new(size)
    local self = setmetatable({}, RingBuffer)
    self.size = size
    self.buffer = {}
    self.pos = 1
    self.count = 0
    return self
end

function RingBuffer:add(value)
    self.buffer[self.pos] = value
    self.pos = (self.pos + 1) % self.size
    if self.count < self.size then
        self.count = self.count + 1
    end
    return self.pos == 1
end

function RingBuffer:get(index)
    return self.buffer[(self.pos - index + self.size) % self.size]
end

function RingBuffer:getLast()
    return self:get(1)
end

function RingBuffer:getLastN(size)
    local arr = {}
    local max = math.min(self.count, size)
    for i = 1, max, 1 do
        arr[i] = self:get(max + 1 - i)
    end
    return arr
end

--#endregion
local secBuffer = RingBuffer.new(60 + 1)
local minBuffer = RingBuffer.new(60 + 1)
local hourBuffer = RingBuffer.new(24 + 1)
local dayBuffer = RingBuffer.new(7 + 1)
--#region Config
local chartWindowSize = 30
local record_rules = {
    { secBuffer, 1, "1 Sec" }, { minBuffer, 1, "1 Min" }, { minBuffer, 10, "10 Min" }, { hourBuffer, 1, "1 Hour" }, { dayBuffer, 1, "1 Day" }
}
--#endregion

--#region Chart
local BRAILLE_MAP = { { 0x0040, 0x0080 }, { 0x0004, 0x0020 }, { 0x0002, 0x0010 }, { 0x0001, 0x0008 } }
local HEIGHT_BRAILLE = 4
local WIDTH_BRAILLE = 2
local Chart = { top = 0, left = 0, width = 0, height = 0, grid = {}, points = {} }
function Chart:initCanvasSize()
    local vW, vH = gpu.getViewport()
    self.top = #record_rules + 2
    self.left = 0
    self.height = (vH - self.top) * HEIGHT_BRAILLE
    self.width = (vW) * WIDTH_BRAILLE
end

function Chart:normalize()
    if #self.points < 1 then
        return
    end
    local startIndex = (#self.points > chartWindowSize) and 2 or 1
    local startPoint = self.points[startIndex]
    local minY, maxY = startPoint[2], startPoint[2]
    for i = startIndex + 1, #self.points, 1 do
        local point = self.points[i]
        minY = math.min(minY, point[2])
        maxY = math.max(maxY, point[2])
    end
    local minDiff = 20
    local deltaY = maxY - minY
    if deltaY < minDiff then
        deltaY = minDiff
    end
    local paddingX = 10
    local paddingY = 10
    local scaleX = (self.width - paddingX * 2) / chartWindowSize
    local scaleY = (self.height - paddingY * 2) / deltaY
    local normalized = {}
    for _, point in ipairs(self.points) do
        local normalizedX = math.floor((point[1] - 1) * scaleX) + paddingX
        local normalizedY = math.floor((point[2] - minY) * scaleY) + paddingY
        table.insert(normalized, { normalizedX, normalizedY })
    end
    self.points = normalized
    for y = 1, self.height do
        self.grid[y] = {}
        for x = 1, self.width do
            self.grid[y][x] = 0
        end
    end
    for _, p in ipairs(self.points) do
        local x, y = p[1], p[2]
        if x >= 0 and x <= self.width and y >= 0 and y <= self.height then
            self.grid[y][x] = 1
        end
    end
end

function Chart:createLines()
    local function bresenham(origin, target)
        local oX, oY = origin[1], origin[2]
        local tX, tY = target[1], target[2]
        local dX = math.abs(tX - oX)
        local dY = math.abs(tY - oY) * -1
        local sX = oX < tX and 1 or -1
        local sY = oY < tY and 1 or -1
        local err = dX + dY
        while true do
            if oX == tX and oY == tY then
                return true
            end
            local tmpErr = 2 * err
            if tmpErr > dY then
                err = err + dY
                oX = oX + sX
            end
            if tmpErr < dX then
                err = err + dX
                oY = oY + sY
            end
            if oX >= 0 and oX <= self.width and oY >= 0 and oY <= self.height then
                self.grid[oY][oX] = 1
            end
        end
    end
    for i = 1, #self.points - 1, 1 do
        bresenham(self.points[i], self.points[i + 1])
    end
end

function Chart:draw()
    local strBuffer = {}
    local iy = 1
    for y = self.height - HEIGHT_BRAILLE + 1, 1, -HEIGHT_BRAILLE do
        local thisRow = {}
        local ix = 1
        for x = 1, self.width - WIDTH_BRAILLE + 1, WIDTH_BRAILLE do
            local charCode = 0x2800
            for dy = 0, HEIGHT_BRAILLE - 1 do
                for dx = 0, WIDTH_BRAILLE - 1 do
                    if self.grid[y + dy][x + dx] == 1 then
                        charCode = charCode + BRAILLE_MAP[dy + 1][dx + 1]
                    end
                end
            end
            thisRow[ix] = utf8.char(charCode)
            ix = ix + 1
        end
        strBuffer[iy] = table.concat(thisRow)
        iy = iy + 1
    end
    for i = 0, iy - 2, 1 do
        gpu.set(self.left, i + self.top, strBuffer[i + 1])
    end
end

local function buildPoints(t)
    local points = {}
    for index, value in ipairs(t) do
        table.insert(points, { index, value })
    end
    return points
end
--#endregion
--#region Stats
local currentEU = 0;
local function getWireless()
    local info = gtm.getSensorInformation()[23]
    local eu_str = string.sub(info, 23, #info - 3)
    eu_str = string.gsub(eu_str, ",", "")
    return tonumber(eu_str)
end
local function formatNumber(n)
    local isNeg = n < 0
    local s = string.format("%.0f", math.abs(n))
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return isNeg and "-" .. s or s
end

local Stats = {}
function Stats:show()
    local statsTable = {}
    local maxLength = 0;
    local formatted = formatNumber(currentEU)
    table.insert(statsTable, { "Total", formatted })
    maxLength = math.max(maxLength, #formatted)
    for _, value in ipairs(record_rules) do
        if (value[1].count >= (value[2] + 1)) then
            formatted = formatNumber(RingBuffer.get(value[1], value[2]) - RingBuffer.get(value[1], value[2] + 1))
            table.insert(statsTable, { value[3], formatted })
            maxLength = math.max(maxLength, #formatted)
        else
            table.insert(statsTable, { value[3], "N/A" })
            maxLength = math.max(maxLength, 3)
        end
    end
    local formatStr = "%-12s %" .. maxLength .. "s EU"
    for _, value in ipairs(statsTable) do
        print(string.format(formatStr, value[1], value[2]))
    end
end

--#endregion
local function main()
    term.setCursorBlink(false)
    Chart:initCanvasSize()
    currentEU = getWireless()
    secBuffer:add(currentEU)
    minBuffer:add(currentEU)
    hourBuffer:add(currentEU)
    dayBuffer:add(currentEU)
    os.sleep(1)
    while true do
        currentEU = getWireless()
        if secBuffer:add(currentEU) then
            if minBuffer:add(currentEU) then
                if hourBuffer:add(currentEU) then
                    dayBuffer:add(currentEU)
                end
            end
        end
        term.clear()
        Stats:show()
        Chart.points = buildPoints(secBuffer:getLastN(chartWindowSize))
        Chart:normalize()
        Chart:createLines()
        Chart:draw()
        os.sleep(1)
    end
end
main()
