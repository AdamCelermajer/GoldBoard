-- The /gb window: Deals (what's worth buying and when), When to sell (what you hold, what it would make
-- now), Overview (gold over time and the week at a glance) and Ledger (every trade).

local _, GB = ...
local UI = GB.UI
local M = {}
GB.Main = M

local WIDTH, HEIGHT = 860, 560
local PAD = UI.PAD
local win, tabs, views = nil, nil, {}

---------------------------------------------------------------------------
-- Numbers from the ledger
---------------------------------------------------------------------------

local KIND = { buy = "Bought", sell = "Sold", post = "Posted", cancel = "Cancelled", expire = "Expired" }
local KIND_COLOR = { buy = "sell", sell = "buy", post = "ink", cancel = "muted", expire = "muted" }

-- per item: buys matched to sales oldest first; what's left is held, at what cost
local function Trades()
  local per = {}
  for _, e in ipairs(GB.db.ledger) do
    -- a sale's mail only carries the name: the item may have been learned since
    if not e.itemID and e.name and GB.db.names[e.name] then e.itemID = GB.db.names[e.name] end
    local id = e.itemID or e.name
    if id then
      local p = per[id]
      if not p then p = { itemID = e.itemID, name = e.name, lots = {}, bought = 0, cost = 0, sold = 0, proceeds = 0, realized = 0 }; per[id] = p end
      if e.kind == "buy" and (e.qty or 0) > 0 then
        p.lots[#p.lots + 1] = { qty = e.qty, unit = (e.price or 0) / e.qty }
        p.bought, p.cost = p.bought + e.qty, p.cost + (e.price or 0)
      elseif e.kind == "sell" then
        local proceeds = (e.price or 0) - (e.cut or 0)
        local qty = math.max(1, e.qty or 1)
        p.sold, p.proceeds = p.sold + qty, p.proceeds + proceeds
        local left, basis, matched = qty, 0, 0
        while left > 0 and #p.lots > 0 do
          local take = math.min(left, p.lots[1].qty)
          basis, matched = basis + take * p.lots[1].unit, matched + take
          p.lots[1].qty, left = p.lots[1].qty - take, left - take
          if p.lots[1].qty <= 0 then table.remove(p.lots, 1) end
        end
        if matched > 0 then p.realized = p.realized + proceeds * matched / qty - basis end
      end
    end
  end
  for _, p in pairs(per) do
    p.held, p.heldCost = 0, 0
    for _, l in ipairs(p.lots) do p.held, p.heldCost = p.held + l.qty, p.heldCost + l.qty * l.unit end
    p.avg = p.held > 0 and p.heldCost / p.held or nil
    local h = p.itemID and GB.db.holdings[p.itemID]
    if h and p.held > 0 then p.held = math.min(p.held, h) end
    -- what you could sell at now: the cheapest listing, never above what it usually sells for
    p.now = p.itemID and GB.AuctionPrice(p.itemID) or nil
    p.gain = (p.avg and p.avg > 0 and p.now) and (p.now * 0.95 - p.avg) / p.avg or nil
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
M.GoldTotal = GoldTotal

-- what you hold that is worth selling now (30% or more over what you paid, after the cut)
local function ReadyToSell(per)
  local n = 0
  for _, p in pairs(per) do if p.held > 0 and p.gain and p.gain >= 0.3 then n = n + 1 end end
  return n
end

-- the line every tab starts with: a big answer on the left, a quiet explanation under it
local function Head(v, noteLines)
  v.head = UI.Text(v, 17, "ink", "LEFT", UI.FONT_TITLE)
  v.head:SetPoint("TOPLEFT", PAD + 2, -16)
  v.head:SetWidth(WIDTH - 2 * PAD - 4)
  v.info = UI.Note(v, WIDTH - 2 * PAD - 4)
  v.info:SetPoint("TOPLEFT", PAD + 2, -42)
  return -(42 + (noteLines or 1) * 15 + 12)   -- where the table starts
end

---------------------------------------------------------------------------
-- Deals: what's worth buying, checked away from the auction house
---------------------------------------------------------------------------

local function BuildDeals(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  local top = Head(v, 2)
  v.info:SetText("Listed under its buy-below price, which leaves 15% profit after the 5% auction cut. From Auctionator's last scan or the last TSM update, whichever is newer. A red trend means it is still falling: let it settle. Buy them at the auction house, in the Shop tab.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "cheapest", label = "Cheapest", width = 96, align = "RIGHT", render = function(d) return UI.Money(d.cheapest) end },
    { key = "sell", label = "Sells for", width = 96, align = "RIGHT", render = function(d) return UI.Color("muted", UI.Money(d.sell)) end },
    { key = "profit", label = "Profit each", width = 100, align = "RIGHT", render = function(d) return UI.Color("buy", UI.Money(d.profit, { sign = true })) end },
    { key = "margin", label = "Margin", width = 62, align = "RIGHT", render = function(d) return UI.Color("buy", UI.Pct(d.margin)) end },
    { key = "trend", label = "Today", width = 58, align = "RIGHT", render = function(d)
        if not d.trend then return UI.Color("faint", "-") end
        return UI.Color(d.trend <= -5 and "sell" or d.trend >= 5 and "buy" or "muted", string.format("%+d%%", d.trend)) end },
    { key = "sold", label = "Sold/day", width = 66, align = "RIGHT", render = function(d) return d.sold and string.format("%.0f", d.sold) or "-" end },
    { key = "when", label = "Best time to buy", width = 130, sort = false, render = function(d)
        if not d.when then return UI.Color("faint", "no pattern yet") end
        return d.whenGood and UI.Verdict("buy", d.when) or UI.Color("muted", d.when) end },
  }, { sortKey = "score", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", PAD, top); v.table:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  return v
end

local function RefreshDeals()
  local v = views.deals
  local list = GB.Pricing.Deals()
  local meta = GB.Signals.Meta()
  v.head:SetText(UI.Color("gold", tostring(#list)) .. (#list == 1 and " deal right now" or " deals right now")
    .. (meta.label and UI.Color("muted", "  on " .. meta.label) or ""))
  if not meta.count or meta.count == 0 then
    v.table:SetData(list, "No prices yet. Start the Gold Board on your PC, let it fetch the TSM prices, then /reload.")
  else
    v.table:SetData(list, "No deals at the last look. They show up here after Auctionator's next scan or the next TSM update.")
  end
  GB.Pricing.FillNames(list, function() if v:IsVisible() then v.table:Refresh() end end)
end

---------------------------------------------------------------------------
-- When to sell: what you bought and still hold
---------------------------------------------------------------------------

local function HoldVerdict(d)
  if not d.gain then return 4, UI.Color("faint", "no price yet") end
  if d.gain >= 0.3 then return 1, UI.Verdict("buy", "Sell now") end
  if d.gain >= 0 then return 2, UI.Verdict("gold", "Small gain") end
  return 3, UI.Verdict("sell", "Hold")
end

local function BuildInventory(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  local top = Head(v, 2)
  v.info:SetText("What you bought at the auction house and still hold. \"Sell now\" means 30% or more over what you paid, after the cut. At the auction house, the Sell tab prices everything in your bags.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "held", label = "Held", width = 56, align = "RIGHT" },
    { key = "avg", label = "Paid each", width = 96, align = "RIGHT", render = function(d) return UI.Color("muted", UI.Money(d.avg)) end },
    { key = "now", label = "Sells at now", width = 100, align = "RIGHT", render = function(d) return d.now and UI.Money(d.now) or UI.Color("faint", "-") end },
    { key = "gain", label = "Gain", width = 66, align = "RIGHT", render = function(d)
        if not d.gain then return UI.Color("faint", "-") end
        return UI.Color(d.gain >= 0 and "buy" or "sell", UI.Pct(d.gain)) end },
    { key = "signal", label = "Verdict", width = 110, sortValue = function(d) return (HoldVerdict(d)) end,
      render = function(d) return select(2, HoldVerdict(d)) end },
    { key = "when", label = "Best time to sell", width = 210, sort = false, render = function(d)
        local s = d.itemID and GB.Signals.Get(d.itemID)
        local text, good = GB.Pricing.SellTiming(s)
        if not text then return UI.Color("faint", "no pattern yet") end
        if good == true then return UI.Color("buy", text) elseif good == false then return UI.Color("sell", text) end
        return UI.Color("muted", text) end },
  }, { sortKey = "gain", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", PAD, top); v.table:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  return v
end

local function RefreshInventory()
  local v = views.inventory
  local list, ready = {}, 0
  for _, p in pairs(Trades()) do
    if p.held > 0 then
      list[#list + 1] = p
      if p.gain and p.gain >= 0.3 then ready = ready + 1 end
    end
  end
  if #list == 0 then v.head:SetText("Nothing held")
  else
    v.head:SetText(UI.Color(ready > 0 and "buy" or "ink", tostring(ready)) .. " to sell now"
      .. UI.Color("muted", "  of " .. #list .. (#list == 1 and " item held" or " items held")))
  end
  v.table:SetData(list, "Nothing held. Items you buy at the auction house show up here with what they'd make now and when to sell them.")
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------

local function Stat(parent, label)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(200, 64)
  UI.Bg(f, UI.C.panel)
  UI.Border(f)
  f.label = UI.Text(f, 12, "muted")
  f.label:SetPoint("TOPLEFT", 12, -10)
  f.label:SetText(label)
  f.value = UI.Text(f, 20, "ink")
  f.value:SetPoint("TOPLEFT", 12, -30)
  return f
end

local function BuildOverview(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.stats = {}
  local gap = (WIDTH - 2 * PAD - 4 * 200) / 3
  for i, label in ipairs({ "Deals right now", "Held items to sell now", "Gold, all characters", "Trading profit, all time" }) do
    local s = Stat(v, label)
    s:SetPoint("TOPLEFT", PAD + (i - 1) * (200 + gap), -PAD)
    v.stats[i] = s
  end
  v.line = UI.Note(v, WIDTH - 2 * PAD - 4, "muted", 13)
  v.line:SetPoint("TOPLEFT", PAD + 2, -92)

  v.chart = CreateFrame("Frame", nil, v)
  v.chart:SetPoint("TOPLEFT", PAD, -136); v.chart:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  UI.Bg(v.chart, UI.C.panel)
  UI.Border(v.chart)
  v.chartTitle = UI.Text(v.chart, 12, "muted")
  v.chartTitle:SetPoint("TOPLEFT", 12, -10)
  v.chartTitle:SetText("Gold over time, all characters")
  v.chartEmpty = UI.Text(v.chart, 13, "muted", "CENTER")
  v.chartEmpty:SetPoint("CENTER")
  v.chartEmpty:SetText("The graph starts after your gold has changed a couple of times.")
  v.lines, v.labels = {}, {}
  return v
end

local MAX_POINTS = 240   -- a line per step: more than the chart has pixels for is wasted

local function DrawGold(v)
  local c = v.chart
  for _, l in ipairs(v.lines) do l:Hide() end
  for _, l in ipairs(v.labels) do l:Hide() end
  local all = GoldTotal()
  v.chartEmpty:SetShown(#all < 2)
  if #all < 2 then return end
  local pts = all
  if #all > MAX_POINTS then
    pts = {}
    local step = (#all - 1) / (MAX_POINTS - 1)
    for i = 0, MAX_POINTS - 1 do pts[#pts + 1] = all[math.floor(i * step + 0.5) + 1] end
  end
  local L, R, T, B = 74, 18, 36, 28
  local W, H = c:GetWidth() - L - R, c:GetHeight() - T - B
  if W <= 0 or H <= 0 then
    if v:IsVisible() then C_Timer.After(0.05, function() DrawGold(v) end) end   -- not laid out yet
    return
  end
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
    fs:SetJustifyH(justify or "LEFT")
    fs:ClearAllPoints()
    fs:SetPoint(justify == "RIGHT" and "RIGHT" or "CENTER", c, "BOTTOMLEFT", x, y)
    fs:SetText(text)
    fs:Show()
  end
  for i = 0, 3 do
    local g = lo + (hi - lo) * i / 3
    Seg(L, Y(g), L + W, Y(g), UI.C.line, 1)
    Label(UI.Money(g, { short = true }), L - 8, Y(g), "RIGHT")
  end
  local fmt = (x1 - x0) > 6 * 86400 and "%d %b" or "%a %H:%M"
  Label(date(fmt, x0), L + 30, 12)
  Label(date(fmt, x1), L + W - 30, 12)
  -- gold moves in steps
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    Seg(X(a[1]), Y(a[2]), X(b[1]), Y(a[2]), UI.C.gold, 2)
    if a[2] ~= b[2] then Seg(X(b[1]), Y(a[2]), X(b[1]), Y(b[2]), UI.C.gold, 2) end
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
  local per = Trades()
  local realized, heldN, heldCost, heldValue = 0, 0, 0, 0
  for _, p in pairs(per) do
    realized = realized + p.realized
    if p.held > 0 then
      heldN = heldN + 1
      heldCost = heldCost + (p.avg or 0) * p.held
      heldValue = heldValue + (p.now and p.now * 0.95 * p.held or 0)
    end
  end
  local deals, ready = #GB.Pricing.Deals(), ReadyToSell(per)
  local pts = GoldTotal()
  v.stats[1].value:SetText(UI.Color(deals > 0 and "gold" or "muted", tostring(deals)))
  v.stats[2].value:SetText(UI.Color(ready > 0 and "buy" or "muted", tostring(ready)))
  v.stats[3].value:SetText(pts[#pts] and UI.Money(pts[#pts][2], { short = true }) or UI.Money(GetMoney(), { short = true }))
  v.stats[4].value:SetText(UI.Color(realized >= 0 and "buy" or "sell", UI.Money(realized, { short = true, sign = true })))
  v.line:SetText(string.format("Last 7 days: bought for %s, sold for %s after the cut (the auction house kept %s). You hold %d item%s you paid %s for, worth about %s now after the cut.",
    UI.Money(spent, { short = true }), UI.Money(earned, { short = true }), UI.Money(fees, { short = true }),
    heldN, heldN == 1 and "" or "s", UI.Money(heldCost, { short = true }), UI.Money(heldValue, { short = true })))
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
  local x = PAD
  for _, f in ipairs({ { "all", "Everything" }, { "buy", "Bought" }, { "sell", "Sold" }, { "post", "Posted" }, { "other", "Expired / cancelled" } }) do
    local b = UI.Button(v, f[2], #f[2] * 7 + 26, 26)
    b:SetPoint("TOPLEFT", x, -PAD)
    x = x + b:GetWidth() + 6
    b:SetScript("OnClick", function() v.filter = f[1]; M.Refresh() end)
    b.key = f[1]
    v.filters[#v.filters + 1] = b
  end
  v.count = UI.Text(v, 12, "muted", "RIGHT")
  v.count:SetPoint("TOPRIGHT", -PAD - 2, -PAD - 7)
  v.table = UI.Table(v, {
    { key = "t", label = "When", width = 100, render = function(d) return UI.Color("muted", UI.When(d.t)) end },
    { key = "kind", label = "What", width = 86, render = function(d) return UI.Color(KIND_COLOR[d.kind] or "ink", KIND[d.kind] or tostring(d.kind)) end },
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "qty", label = "Qty", width = 50, align = "RIGHT" },
    { key = "each", label = "Each", width = 100, align = "RIGHT", sortValue = function(d) return d.total and d.qty and d.qty > 0 and d.total / d.qty or 0 end,
      render = function(d) return (d.total and d.qty and d.qty > 0) and UI.Money(d.total / d.qty) or UI.Color("faint", "-") end },
    { key = "total", label = "Total", width = 110, align = "RIGHT", render = function(d) return d.total and UI.Money(d.total) or UI.Color("faint", "-") end },
    { key = "char", label = "Character", width = 130, render = function(d) return UI.Color("muted", ((d.char or ""):gsub("%-.*$", ""))) end },
  }, { sortKey = "t", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", PAD, -(PAD + 26 + 10)); v.table:SetPoint("BOTTOMRIGHT", -PAD, PAD)
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
  for _, b in ipairs(v.filters) do
    local on = b.key == v.filter
    b.text:SetTextColor(unpack(on and UI.C.gold or UI.C.ink))
  end
  v.count:SetText(#list .. (#list == 1 and " entry" or " entries"))
  v.table:SetData(list, v.filter == "all"
    and "Nothing recorded yet. Buys, sales, posts and expiries at the auction house and the mailbox show up here, and on the Gold Board after a /reload."
    or "Nothing of this kind recorded yet.")
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local REFRESH = { deals = RefreshDeals, inventory = RefreshInventory, overview = RefreshOverview, ledger = RefreshLedger }

local function Build()
  win = UI.Window("GoldBoardMainWindow", WIDTH, HEIGHT, "Gold Board", "mainPos")
  UI.RestorePosition(win, "mainPos")
  local body = CreateFrame("Frame", nil, win)
  body:SetPoint("TOPLEFT", 0, -UI.TOP); body:SetPoint("BOTTOMRIGHT")
  views.deals, views.inventory, views.overview, views.ledger = BuildDeals(body), BuildInventory(body), BuildOverview(body), BuildLedger(body)
  UI.Rule(win, -(UI.TOP - 1))
  tabs = UI.Tabs(win, { { key = "deals", label = "Deals" }, { key = "inventory", label = "When to sell" },
    { key = "overview", label = "Overview" }, { key = "ledger", label = "Ledger" } }, function(key)
    for k, view in pairs(views) do view:SetShown(k == key) end
    GB.db.settings.mainTab = key
    REFRESH[key]()
  end)
  tabs:SetPoint("TOPLEFT", PAD - 6, -UI.HEAD); tabs:SetPoint("TOPRIGHT", -PAD, -UI.HEAD)
  win:SetScript("OnShow", function()
    win.sub:SetText(GB.Signals.Describe())
    local key = GB.db.settings.mainTab
    tabs:Select(REFRESH[key] and key or "deals")
  end)
end

function M.Refresh()
  if win and win:IsShown() and tabs.selected and REFRESH[tabs.selected] then REFRESH[tabs.selected]() end
end

function M.Toggle()
  if not win then Build() end
  win:SetShown(not win:IsShown())
end
