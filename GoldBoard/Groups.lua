-- Groups of items you trade, each with its pricing rules (TSM calls them operations):
--   min     never post below this share of the item's value (protects you from a price crash)
--   normal  what to post at when nobody else is selling
--   max     never post above this (an outlier listing doesn't drag you up)
--   undercut how much under the cheapest other seller to go, per item
--   stack, stacks, keep, duration
-- "Value" is the Gold Board's "sells for" price, or Auctionator's last scan price when the
-- dashboard has none for the item.

local _, GB = ...
local G = {}
GB.Groups = G

G.DEFAULT_RULES = { min = 80, normal = 120, max = 200, undercut = 1, stack = 20, stacks = 5, keep = 0, duration = 1, belowMin = "skip" }
G.DURATIONS = { [1] = "Short", [2] = "Medium", [3] = "Long" }

function G.All()
  GB.db.groups = GB.db.groups or {}
  return GB.db.groups
end

function G.Create(name)
  local all = G.All()
  if not name or name == "" or all[name] then return nil end
  local rules = {}
  for k, v in pairs(G.DEFAULT_RULES) do rules[k] = v end
  all[name] = { items = {}, rules = rules, created = time() }
  return all[name]
end

function G.Delete(name) G.All()[name] = nil end

function G.Rename(old, new)
  local all = G.All()
  if not all[old] or not new or new == "" or all[new] then return false end
  all[new], all[old] = all[old], nil
  return true
end

function G.AddItem(name, itemID)
  local g = G.All()[name]
  if g and itemID then g.items[itemID] = true end
end

function G.RemoveItem(name, itemID)
  local g = G.All()[name]
  if g then g.items[itemID] = nil end
end

-- the group an item belongs to (first found) and its rules
function G.ForItem(itemID)
  for name, g in pairs(G.All()) do
    if g.items[itemID] then return name, g.rules end
  end
end

function G.SortedNames()
  local out = {}
  for name in pairs(G.All()) do out[#out + 1] = name end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

-- what an item is worth to the pricing rules, and where that number came from
function G.Value(itemID)
  local s = GB.Signals.Get(itemID)
  if s and s.sell and s.sell > 0 then return s.sell, "Gold Board" end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID
  if api then
    local ok, p = pcall(api, "Gold Board", itemID)
    if ok and p and p > 0 then return p, "Auctionator" end
  end
end

-- Prices the rules allow for an item: { min, normal, max } per item in copper, or nil without a value
function G.Prices(itemID, rules)
  local value, source = G.Value(itemID)
  if not value then return nil end
  return { min = math.floor(value * rules.min / 100), normal = math.floor(value * rules.normal / 100),
           max = math.floor(value * rules.max / 100), value = value, source = source }
end

-- Decide a post: lowest = cheapest other seller's unit price (nil = nobody), mineLowest = you're already cheapest.
-- Returns unit price and a plain reason, or nil and why not.
function G.PostPrice(prices, rules, lowest, mineLowest)
  if not prices then return nil, "no price known yet" end
  if mineLowest then return nil, "you're already the cheapest" end
  if not lowest then return prices.normal, "nobody else sells it: normal price" end
  local under = lowest - (rules.undercut or 1)
  if under > prices.max then return prices.max, "others are above your maximum: posting at maximum" end
  if under < prices.min then
    if rules.belowMin == "max" then return prices.max, "others are below your minimum: posting at maximum to wait it out" end
    return nil, "others are below your minimum"
  end
  return under, "undercutting the cheapest by " .. GB.UI.Money(rules.undercut or 1)
end
