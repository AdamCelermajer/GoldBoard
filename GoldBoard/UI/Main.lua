-- The /gb window: Overview (gold over time and the week at a glance), Ledger (every trade),
-- Inventory (what you hold and what it would make now) and Groups (what you trade and its pricing rules).

local _, GB = ...
local UI = GB.UI
local M = {}
GB.Main = M

local WIDTH, HEIGHT = 820, 540
local win, tabs, views = nil, nil, {}

---------------------------------------------------------------------------
-- Numbers from the ledger
---------------------------------------------------------------------------

local KIND = { buy = "Bought", sell = "Sold", post = "Posted", cancel = "Cancelled", expire = "Expired" }

-- per item: buys matched to sales oldest first; what's left is held, at what cost
local function Trades()
  local per = {}
  for _, e in ipairs(GB.db.ledger) do
    local id = e.itemID or e.name
    if id then
      local p = per[id]
      if not p then p = { itemID = e.itemID, name = e.name, lots = {}, bought = 0, cost = 0, sold = 0, proceeds = 0, realized = 0 }; per[id] = p end
      if e.kind == "buy" and (e.qty or 0) > 0 then
        p.lots[#p.lots + 1] = { qty = e.qty, unit = (e.price or 0) / e.qty }
        p.bought, p.cost = p.bought + e.qty, p.cost + (e.price or 0)
      elseif e.kind == "sell" then
        local proceeds = (e.price or 0) - (e.cut or 0)
        p.sold, p.proceeds = p.sold + (e.qty or 0), p.proceeds + proceeds
        local left, basis, matched = e.qty or 0, 0, 0
        while left > 0 and #p.lots > 0 do
          local take = math.min(left, p.lots[1].qty)
          basis, matched = basis + take * p.lots[1].unit, matched + take
          p.lots[1].qty, left = p.lots[1].qty - take, left - take
          if p.lots[1].qty <= 0 then table.remove(p.lots, 1) end
        end
        if matched > 0 then p.realized = p.realized + proceeds * matched / (e.qty or matched) - basis end
      end
    end
  end
  for _, p in pairs(per) do
    p.held, p.heldCost = 0, 0
    for _, l in ipairs(p.lots) do p.held, p.heldCost = p.held + l.qty, p.heldCost + l.qty * l.unit end
    p.avg = p.held > 0 and p.heldCost / p.held or nil
    local h = p.itemID and GB.db.holdings[p.itemID]
    if h and p.held > 0 then p.held = math.min(p.held, h) end
    local s = p.itemID and GB.Signals.Get(p.itemID)
    -- what you could sell at now: the cheapest listing, never above what it usually sells for
    p.now = s and s.sell and (((s.minBuy or 0) > 0) and math.min(s.sell, s.minBuy) or s.sell) or nil
    p.gain = (p.avg and p.now) and (p.now * 0.95 - p.avg) / p.avg or nil
  end
  return per
end
M.Trades = Trades

local function GoldTotal()
  local events = {}
  for name, c in pairs(GB.db.chars) do
    for _, s in ipairs(c.gold or {}) do events[#events + 1] = { s[1], name, s[2] } end
  end
  table.sort(events, function(a, b) return a[1] < b[1] end)
  local last, out = {}, {}
  for _, e in ipairs(events) do
    last[e[2]] = e[3]
    local total = 0
    for _, v in pairs(last) do total = total + v end
    out[#out + 1] = { e[1], total }
  end
  return out
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------

local function Stat(parent, label)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(180, 54)
  f.label = UI.Text(f, 12, "muted")
  f.label:SetPoint("TOPLEFT")
  f.label:SetText(label)
  f.value = UI.Text(f, 20, "ink")
  f.value:SetPoint("TOPLEFT", 0, -18)
  return f
end

local function BuildOverview(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.stats = {}
  for i, label in ipairs({ "Gold now, all characters", "Bought, last 7 days", "Sold after the cut, 7 days", "Trading profit, all time" }) do
    local s = Stat(v, label)
    s:SetPoint("TOPLEFT", 18 + (i - 1) * 198, -16)
    v.stats[i] = s
  end
  local rule = v:CreateTexture(nil, "BORDER")
  UI.Fill(rule, UI.C.brass)
  rule:SetHeight(2)
  rule:SetPoint("TOPLEFT", 16, -78); rule:SetPoint("TOPRIGHT", -16, -78)
  v.line = UI.Text(v, 13, "ink")
  v.line:SetPoint("TOPLEFT", 18, -90)
  v.line:SetWidth(WIDTH - 36)
  v.line:SetWordWrap(true)

  v.chart = CreateFrame("Frame", nil, v)
  v.chart:SetPoint("TOPLEFT", 16, -130); v.chart:SetPoint("BOTTOMRIGHT", -16, 16)
  UI.Bg(v.chart, UI.C.panel)
  UI.Border(v.chart)
  v.chartTitle = UI.Text(v.chart, 13, "muted")
  v.chartTitle:SetPoint("TOPLEFT", 12, -10)
  v.chartTitle:SetText("Gold over time, all characters")
  v.lines, v.labels = {}, {}
  return v
end

local function DrawGold(v)
  local c = v.chart
  for _, l in ipairs(v.lines) do l:Hide() end
  for _, l in ipairs(v.labels) do l:Hide() end
  local pts = GoldTotal()
  if #pts < 2 then
    v.labels[1] = v.labels[1] or UI.Text(c, 13, "muted", "CENTER")
    v.labels[1]:ClearAllPoints()
    v.labels[1]:SetPoint("CENTER")
    v.labels[1]:SetText("The graph starts after your gold changes a couple of times.")
    v.labels[1]:Show()
    return
  end
  local L, R, T, B = 70, 16, 34, 26
  local W, H = c:GetWidth() - L - R, c:GetHeight() - T - B
  if W <= 0 or H <= 0 then C_Timer.After(0.05, function() DrawGold(v) end) return end   -- not laid out yet
  local x0, x1 = pts[1][1], pts[#pts][1]
  local lo, hi = math.huge, 0
  for _, p in ipairs(pts) do lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end
  lo, hi = lo * 0.97, hi * 1.03 + 1
  local function X(t) return L + (t - x0) / math.max(1, x1 - x0) * W end
  local function Y(g) return B + (g - lo) / (hi - lo) * H end
  local n = 0
  local function Seg(ax, ay, bx, by, color, thick)
    n = n + 1
    local l = v.lines[n] or c:CreateLine(nil, "ARTWORK")
    v.lines[n] = l
    l:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    l:SetThickness(thick or 2)
    l:SetStartPoint("BOTTOMLEFT", c, ax, ay)
    l:SetEndPoint("BOTTOMLEFT", c, bx, by)
    l:Show()
  end
  local ln = 0
  local function Label(text, x, y, justify)
    ln = ln + 1
    local fs = v.labels[ln] or UI.Text(c, 11, "muted", justify)
    v.labels[ln] = fs
    fs:ClearAllPoints()
    fs:SetPoint(justify == "RIGHT" and "RIGHT" or "CENTER", c, "BOTTOMLEFT", x, y)
    fs:SetText(text)
    fs:Show()
  end
  for i = 0, 3 do
    local g = lo + (hi - lo) * i / 3
    Seg(L, Y(g), L + W, Y(g), UI.C.line, 1)
    Label(UI.Money(g, { short = true }), L - 6, Y(g), "RIGHT")
  end
  Label(date("%a %H:%M", x0), L + 30, 12)
  Label(date("%a %H:%M", x1), L + W - 30, 12)
  -- gold moves in steps
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    Seg(X(a[1]), Y(a[2]), X(b[1]), Y(a[2]), UI.C.brass, 2)
    Seg(X(b[1]), Y(a[2]), X(b[1]), Y(b[2]), UI.C.brass, 2)
  end
end

local function RefreshOverview()
  local v = views.overview
  local week = time() - 7 * 86400
  local spent, earned, fees = 0, 0, 0
  for _, e in ipairs(GB.db.ledger) do
    if (e.t or 0) >= week then
      if e.kind == "buy" then spent = spent + (e.price or 0)
      elseif e.kind == "sell" then earned = earned + (e.price or 0) - (e.cut or 0); fees = fees + (e.cut or 0) end
    end
  end
  local realized, heldN, heldCost, heldValue = 0, 0, 0, 0
  for _, p in pairs(Trades()) do
    realized = realized + p.realized
    if p.held > 0 then
      heldN = heldN + 1
      heldCost = heldCost + (p.avg or 0) * p.held
      heldValue = heldValue + (p.now and p.now * 0.95 * p.held or 0)
    end
  end
  local pts = GoldTotal()
  v.stats[1].value:SetText(pts[#pts] and UI.Money(pts[#pts][2], { short = true }) or UI.Money(GetMoney(), { short = true }))
  v.stats[2].value:SetText(UI.Money(spent, { short = true }))
  v.stats[3].value:SetText(UI.Money(earned, { short = true }))
  v.stats[4].value:SetText(UI.Color(realized >= 0 and "buy" or "sell", UI.Money(realized, { short = true, sign = true })))
  v.line:SetText(string.format("You hold %d item%s you bought for %s, worth about %s now after the cut. Auction house cut this week: %s. Prices: %s.",
    heldN, heldN == 1 and "" or "s", UI.Money(heldCost, { short = true }), UI.Money(heldValue, { short = true }), UI.Money(fees, { short = true }),
    GB.Signals.Describe()))
  DrawGold(v)
end

---------------------------------------------------------------------------
-- Ledger
---------------------------------------------------------------------------

local function BuildLedger(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.filter = "all"
  v.filters = {}
  local x = 16
  for _, f in ipairs({ { "all", "Everything" }, { "buy", "Bought" }, { "sell", "Sold" }, { "post", "Posted" }, { "other", "Expired / cancelled" } }) do
    local b = UI.Button(v, f[2], #f[2] * 7 + 24, 24, "quiet")
    b:SetPoint("TOPLEFT", x, -12)
    x = x + b:GetWidth() + 6
    b:SetScript("OnClick", function() v.filter = f[1]; M.Refresh() end)
    b.key = f[1]
    v.filters[#v.filters + 1] = b
  end
  v.table = UI.Table(v, {
    { key = "t", label = "When", width = 96, render = function(d) return UI.When(d.t) end },
    { key = "kind", label = "What", width = 86, render = function(d) return KIND[d.kind] or d.kind end },
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "qty", label = "Qty", width = 50, align = "RIGHT" },
    { key = "each", label = "Each", width = 100, align = "RIGHT", sortValue = function(d) return d.total and d.qty and d.total / d.qty or 0 end,
      render = function(d) return (d.total and d.qty and d.qty > 0) and UI.Money(d.total / d.qty) or "-" end },
    { key = "total", label = "Total", width = 110, align = "RIGHT", render = function(d) return d.total and UI.Money(d.total) or "-" end },
    { key = "char", label = "Character", width = 120, render = function(d) return UI.Color("muted", (d.char or ""):gsub("%-.*$", "")) end },
  }, { sortKey = "t", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 12, -46); v.table:SetPoint("BOTTOMRIGHT", -12, 12)
  return v
end

local function RefreshLedger()
  local v = views.ledger
  local list = {}
  for _, e in ipairs(GB.db.ledger) do
    local keep = v.filter == "all" or e.kind == v.filter or (v.filter == "other" and (e.kind == "expire" or e.kind == "cancel"))
    if keep then
      local total = e.kind == "sell" and ((e.price or 0) - (e.cut or 0)) or e.price
      list[#list + 1] = { t = e.t, kind = e.kind, itemID = e.itemID, name = e.name, qty = e.qty, total = total, char = e.char }
    end
  end
  for _, b in ipairs(v.filters) do b.text:SetTextColor(unpack(b.key == v.filter and UI.C.brass or UI.C.ink)) end
  v.table:SetData(list, "Nothing recorded yet. Buys and sales at the auction house show up here, and on the Gold Board after a /reload.")
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------

local function BuildInventory(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.info = UI.Text(v, 13, "muted")
  v.info:SetPoint("TOPLEFT", 18, -16)
  v.info:SetWidth(WIDTH - 36)
  v.info:SetText("What you bought at the auction house and still hold. \"Sell now\" means 30% or more over what you paid, after the cut.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "held", label = "Held", width = 60, align = "RIGHT" },
    { key = "avg", label = "Paid each", width = 110, align = "RIGHT", render = function(d) return UI.Money(d.avg) end },
    { key = "now", label = "Could sell at now", width = 130, align = "RIGHT", render = function(d) return d.now and UI.Money(d.now) or "-" end },
    { key = "gain", label = "Gain", width = 70, align = "RIGHT", render = function(d)
        if not d.gain then return "-" end
        return UI.Color(d.gain >= 0 and "buy" or "sell", UI.Pct(d.gain)) end },
    { key = "signal", label = "Signal", width = 110, sortValue = function(d) return d.gain or -9 end, render = function(d)
        if not d.gain then return UI.Color("muted", "no price yet") end
        if d.gain >= 0.3 then return UI.Color("buy", "sell now") end
        if d.gain >= 0 then return "hold or sell" end
        return UI.Color("sell", "hold") end },
  }, { sortKey = "gain", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 12, -42); v.table:SetPoint("BOTTOMRIGHT", -12, 12)
  return v
end

local function RefreshInventory()
  local list = {}
  for _, p in pairs(Trades()) do if p.held > 0 then list[#list + 1] = p end end
  views.inventory.table:SetData(list, "Nothing held. Items you buy at the auction house show up here with what they'd make now.")
end

---------------------------------------------------------------------------
-- Groups
---------------------------------------------------------------------------

local RULE_FIELDS = {
  { key = "min", label = "Minimum", suffix = "% of value" },
  { key = "normal", label = "Normal (nobody selling)", suffix = "% of value" },
  { key = "max", label = "Maximum", suffix = "% of value" },
  { key = "undercut", label = "Undercut by", suffix = "copper" },
  { key = "stack", label = "Stack size", suffix = nil },
  { key = "stacks", label = "Stacks to post", suffix = nil },
  { key = "keep", label = "Keep in bags", suffix = nil },
  { key = "duration", label = "Duration (1 short, 2, 3 long)", suffix = nil },
}

local function BuildGroups(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  -- left: the groups
  v.name = UI.Input(v, 150, "New group name")
  v.name:SetPoint("TOPLEFT", 12, -12)
  v.new = UI.Button(v, "Create", 60, 24)
  v.new:SetPoint("LEFT", v.name, "RIGHT", 6, 0)
  v.list = UI.Table(v, {
    { key = "name", label = "Group", width = 0 },
    { key = "n", label = "Items", width = 50, align = "RIGHT" },
  }, { sortKey = "name", sortDir = 1, onClick = function(_, d) v.current = d.name; M.Refresh() end })
  v.list:SetPoint("TOPLEFT", 12, -44); v.list:SetPoint("BOTTOMLEFT", 12, 46)
  v.list:SetWidth(218)
  v.delete = UI.Button(v, "Delete group", 106, 24, "quiet")
  v.delete:SetPoint("BOTTOMLEFT", 12, 12)
  v.rename = UI.Button(v, "Rename", 106, 24, "quiet")
  v.rename:SetPoint("LEFT", v.delete, "RIGHT", 6, 0)

  -- middle: rules
  v.rulesTitle = UI.Text(v, 15, "ink", "LEFT", UI.FONT_TITLE)
  v.rulesTitle:SetPoint("TOPLEFT", 248, -16)
  v.fields = {}
  for i, f in ipairs(RULE_FIELDS) do
    local field = UI.NumberField(v, f.label, f.suffix, 250)
    field:SetPoint("TOPLEFT", 248, -40 - (i - 1) * 30)
    field.key = f.key
    field.box:SetScript("OnEditFocusLost", function(self)
      local g = v.current and GB.Groups.All()[v.current]
      local n = tonumber(self:GetText())
      if g and n then g.rules[f.key] = n end
    end)
    field.box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    v.fields[i] = field
  end
  v.help = UI.Text(v, 12, "muted")
  v.help:SetPoint("TOPLEFT", 248, -40 - #RULE_FIELDS * 30 - 6)
  v.help:SetWidth(250)
  v.help:SetWordWrap(true)
  v.help:SetText("Value = the Gold Board's \"sells for\" price (or Auctionator's last scan). Posting undercuts the cheapest other seller, never below Minimum or above Maximum.")

  -- right: items in the group, and your bags to add from
  v.items = UI.Table(v, {
    { key = "name", label = "In this group (click to remove)", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
  }, { sortKey = "name", sortDir = 1, onClick = function(_, d) GB.Groups.RemoveItem(v.current, d.itemID); M.Refresh() end,
       onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.items:SetPoint("TOPLEFT", 516, -12); v.items:SetPoint("TOPRIGHT", -12, -12)
  v.items:SetHeight(220)
  v.bags = UI.Table(v, {
    { key = "name", label = "Your bags (click to add)", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "count", label = "", width = 40, align = "RIGHT" },
  }, { sortKey = "name", sortDir = 1, onClick = function(_, d) if v.current then GB.Groups.AddItem(v.current, d.itemID); M.Refresh() end end,
       onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.bags:SetPoint("TOPLEFT", v.items, "BOTTOMLEFT", 0, -8); v.bags:SetPoint("BOTTOMRIGHT", -12, 12)

  v.new:SetScript("OnClick", function()
    local name = v.name:GetText()
    if GB.Groups.Create(name) then v.current = name; v.name:SetText(""); v.name:ClearFocus() end
    M.Refresh()
  end)
  v.name:SetScript("OnEnterPressed", function() v.new:Click() end)
  v.delete:SetScript("OnClick", function()
    if v.current then GB.Groups.Delete(v.current); v.current = nil; M.Refresh() end
  end)
  v.rename:SetScript("OnClick", function()
    local new = v.name:GetText()
    if v.current and GB.Groups.Rename(v.current, new) then v.current = new; v.name:SetText("") end
    M.Refresh()
  end)
  return v
end

local function RefreshGroups()
  local v = views.groups
  local all = GB.Groups.All()
  if v.current and not all[v.current] then v.current = nil end
  if not v.current then v.current = GB.Groups.SortedNames()[1] end
  local list, sel = {}, nil
  for name, g in pairs(all) do
    local n = 0
    for _ in pairs(g.items) do n = n + 1 end
    local d = { name = name, n = n }
    list[#list + 1] = d
    if name == v.current then sel = d end
  end
  v.list.selected = sel
  v.list:SetData(list, "No groups yet. Type a name above and press Create.")
  local g = v.current and all[v.current]
  v.rulesTitle:SetText(g and ("Rules for " .. v.current) or "Make a group to set its rules")
  for _, field in ipairs(v.fields) do
    field:Set(g and g.rules[field.key])
    field:SetShown(g ~= nil)
  end
  v.help:SetShown(g ~= nil)
  local items = {}
  if g then for id in pairs(g.items) do items[#items + 1] = { itemID = id, name = C_Item.GetItemNameByID(id) or ("item " .. id) } end end
  v.items:SetData(items, g and "Click items in your bags below to add them." or "")
  local bags, seen = {}, {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.isBound and not (g and g.items[info.itemID]) then
        local e = seen[info.itemID]
        if not e then
          e = { itemID = info.itemID, name = C_Item.GetItemNameByID(info.itemID) or ("item " .. info.itemID), count = 0 }
          seen[info.itemID] = e
          bags[#bags + 1] = e
        end
        e.count = e.count + (info.stackCount or 1)
      end
    end
  end
  v.bags:SetData(bags, "Nothing tradeable in your bags.")
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local REFRESH = { overview = RefreshOverview, ledger = RefreshLedger, inventory = RefreshInventory, groups = RefreshGroups }

local function Build()
  win = UI.Window("GoldBoardMainWindow", WIDTH, HEIGHT, "Gold Board")
  local body = CreateFrame("Frame", nil, win)
  body:SetPoint("TOPLEFT", 0, -63); body:SetPoint("BOTTOMRIGHT")
  views.overview, views.ledger, views.inventory, views.groups = BuildOverview(body), BuildLedger(body), BuildInventory(body), BuildGroups(body)
  local rule = win:CreateTexture(nil, "BORDER")
  UI.Fill(rule, UI.C.line)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 0, -62); rule:SetPoint("TOPRIGHT", 0, -62)
  tabs = UI.Tabs(win, { { key = "overview", label = "Overview" }, { key = "ledger", label = "Ledger" },
    { key = "inventory", label = "Inventory" }, { key = "groups", label = "Groups" } }, function(key)
    for k, view in pairs(views) do view:SetShown(k == key) end
    GB.db.settings.mainTab = key
    REFRESH[key]()
  end)
  tabs:SetPoint("TOPLEFT", 8, -34); tabs:SetPoint("TOPRIGHT", -8, -34)
  win:SetScript("OnShow", function() win.sub:SetText(GB.Signals.Describe()) tabs:Select(GB.db.settings.mainTab or "overview") end)
end

function M.Refresh()
  if win and win:IsShown() and tabs.selected then REFRESH[tabs.selected]() end
end

function M.Toggle()
  if not win then Build() end
  win:SetShown(not win:IsShown())
end
