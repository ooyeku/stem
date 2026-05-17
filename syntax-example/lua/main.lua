-- OO via metatables. Run with: lua main.lua

local Queue = {}
Queue.__index = Queue

function Queue.new()
    return setmetatable({ first = 1, last = 0, items = {} }, Queue)
end

function Queue:push(value)
    self.last = self.last + 1
    self.items[self.last] = value
end

function Queue:pop()
    if self.first > self.last then return nil end
    local value = self.items[self.first]
    self.items[self.first] = nil
    self.first = self.first + 1
    return value
end

function Queue:size()
    return self.last - self.first + 1
end

local function range(a, b, step)
    step = step or 1
    local i = a - step
    return function()
        i = i + step
        if (step > 0 and i <= b) or (step < 0 and i >= b) then return i end
    end
end

local q = Queue.new()
for n in range(1, 5) do q:push(n * n) end

print(string.format("queue size: %d", q:size()))
while q:size() > 0 do
    io.write(q:pop(), " ")
end
print()
