-- Gold Board's look: flat panels in the dashboard's colors (deep lagoon blue, brass, verdigris for
-- "cheap / buy", ember for "dear / sell"), condensed type for numbers. Every window is built from
-- these few parts so they all look the same.

local _, GB = ...
local UI = {}
GB.UI = UI

UI.C = {
  bg      = { 0.059, 0.145, 0.188, 0.97 },  -- #0f2530
  panel   = { 0.082, 0.192, 0.239, 1 },     -- #15313d
  panel2  = { 0.106, 0.231, 0.282, 1 },     -- #1b3b48
  line    = { 0.149, 0.286, 0.353, 1 },     -- #26495a
  ink     = { 0.922, 0.898, 0.827, 1 },     -- #ebe5d3
  muted   = { 0.616, 0.702, 0.710, 1 },     -- #9db3b5
  brass   = { 0.851, 0.671, 0.310, 1 },     -- #d9ab4f
  buy     = { 0.361, 0.769, 0.678, 1 },     -- #5cc4ad
  sell    = { 0.937, 0.478, 0.361, 1 },     -- #ef7a5c
}
UI.HEX = { ink = "ebe5d3", muted = "9db3b5", brass = "d9ab4f", buy = "5cc4ad", sell = "ef7a5c" }
function UI.Color(name, text) return "|cff" .. UI.HEX[name] .. text .. "|r" end

UI.FONT_TEXT = "Fonts\\ARIALN.TTF"      -- condensed: numbers, tables, labels
UI.FONT_TITLE = "Fonts\\FRIZQT__.TTF"   -- the game's own face, for titles

local function Fill(tex, c) tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
UI.Fill = Fill

-- 1-pixel border around a frame
function UI.Border(f, c)
  c = c or UI.C.line
  local function Edge(p1, p2, w, h)
    local t = f:CreateTexture(nil, "BORDER")
    Fill(t, c)
    t:SetPoint(p1); t:SetPoint(p2)
    if w then t:SetWidth(w) else t:SetHeight(h) end
    return t
  end
  f.borders = { Edge("TOPLEFT", "TOPRIGHT", nil, 1), Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1),
                Edge("TOPLEFT", "BOTTOMLEFT", 1), Edge("TOPRIGHT", "BOTTOMRIGHT", 1) }
end

function UI.Bg(f, c, layer)
  local t = f:CreateTexture(nil, layer or "BACKGROUND")
  Fill(t, c or UI.C.panel)
  t:SetAllPoints()
  return t
end

function UI.Text(parent, size, color, justify, font)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(font or UI.FONT_TEXT, size or 13, "")
  local c = UI.C[color or "ink"] or color
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

-- Money with the game's coin icons: 12g 34s 56c (silver and copper dropped where they don't matter)
function UI.Money(c, opts)
  c = GB.Clean(c)
  if not c then return UI.Color("muted", "-") end
  opts = opts or {}
  local neg = c < 0
  c = math.floor(math.abs(c) + 0.5)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local G = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
  local S = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
  local Cc = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
  local parts = {}
  if g > 0 then parts[#parts + 1] = (g >= 1000 and BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g) .. G end
  if s > 0 or (g > 0 and not opts.short) then parts[#parts + 1] = s .. S end
  if g == 0 and (cc > 0 or s == 0) then parts[#parts + 1] = cc .. Cc end
  local out = table.concat(parts, " ")
  if neg then out = "-" .. out elseif opts.sign then out = "+" .. out end
  return out
end

function UI.Pct(v, signed)
  if not v or v ~= v then return UI.Color("muted", "-") end
  local s = string.format("%s%d%%", (signed ~= false and v > 0) and "+" or "", math.floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
  return s
end

-- item name in its quality color, with its icon
function UI.ItemText(itemID, fallback)
  local name = itemID and (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or fallback or "?"
  local q = itemID and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)
  local icon = itemID and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
  local color = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] and ITEM_QUALITY_COLORS[q].hex or "|cffffffff"
  return (icon and ("|T" .. icon .. ":0:0:0:0:64:64:5:59:5:59|t ") or "") .. color .. (name or fallback or "?") .. "|r"
end

function UI.Ago(t)
  if not t then return "-" end
  local m = math.floor((time() - t) / 60)
  if m < 1 then return "just now" elseif m < 60 then return m .. " min ago" elseif m < 2880 then return math.floor(m / 60) .. " h ago" end
  return math.floor(m / 1440) .. " days ago"
end

function UI.When(t) return t and date("%a %H:%M", t) or "-" end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

-- kind: "primary" (brass, the one action that matters), "normal", "quiet"
function UI.Button(parent, label, w, h, kind)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w or 100, h or 24)
  b.kind = kind or "normal"
  b.bg = UI.Bg(b, b.kind == "primary" and UI.C.brass or UI.C.panel2, "BACKGROUND")
  if b.kind ~= "quiet" then UI.Border(b, b.kind == "primary" and UI.C.brass or UI.C.line) end
  b.text = UI.Text(b, 13, b.kind == "primary" and { 0.06, 0.1, 0.12, 1 } or "ink", "CENTER")
  b.text:SetPoint("CENTER")
  b.text:SetText(label)
  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints()
  b.hl:SetColorTexture(1, 1, 1, 0.08)
  function b:SetLabel(t) self.text:SetText(t) end
  b:SetScript("OnEnable", function(self) self:SetAlpha(1) end)
  b:SetScript("OnDisable", function(self) self:SetAlpha(0.4) end)
  return b
end

function UI.Input(parent, w, placeholder)
  local e = CreateFrame("EditBox", nil, parent)
  e:SetSize(w or 160, 24)
  e:SetAutoFocus(false)
  e:SetFont(UI.FONT_TEXT, 13, "")
  e:SetTextColor(unpack(UI.C.ink))
  e:SetTextInsets(8, 8, 0, 0)
  UI.Bg(e, UI.C.bg)
  UI.Border(e)
  e.hint = UI.Text(e, 13, "muted")
  e.hint:SetPoint("LEFT", 8, 0)
  e.hint:SetText(placeholder or "")
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:HookScript("OnTextChanged", function(self) self.hint:SetShown(self:GetText() == "") end)
  return e
end

-- small labelled number box for settings ("Minimum  80 %")
function UI.NumberField(parent, label, suffix, w)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(w or 220, 24)
  f.label = UI.Text(f, 13, "muted")
  f.label:SetPoint("LEFT")
  f.label:SetText(label)
  f.box = UI.Input(f, 64)
  f.box:SetPoint("RIGHT", -(suffix and 30 or 0), 0)
  f.box:SetJustifyH("RIGHT")
  f.box:SetNumeric(false)
  if suffix then
    f.suffix = UI.Text(f, 13, "muted")
    f.suffix:SetPoint("LEFT", f.box, "RIGHT", 6, 0)
    f.suffix:SetText(suffix)
  end
  function f:Get() return tonumber(self.box:GetText()) end
  function f:Set(v) self.box:SetText(v and tostring(v) or "") end
  return f
end

-- a row of tabs; onSelect(key)
function UI.Tabs(parent, items, onSelect)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetHeight(28)
  bar.buttons = {}
  local x = 0
  for _, it in ipairs(items) do
    local b = CreateFrame("Button", nil, bar)
    b.key = it.key
    b.text = UI.Text(b, 14, "muted", "CENTER", UI.FONT_TITLE)
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(it.label)
    b:SetSize(b.text:GetStringWidth() + 28, 28)
    b:SetPoint("LEFT", x, 0)
    x = x + b:GetWidth() + 2
    b.under = b:CreateTexture(nil, "ARTWORK")
    UI.Fill(b.under, UI.C.brass)
    b.under:SetHeight(2)
    b.under:SetPoint("BOTTOMLEFT", 8, 0)
    b.under:SetPoint("BOTTOMRIGHT", -8, 0)
    b:SetScript("OnClick", function() bar:Select(it.key) end)
    bar.buttons[#bar.buttons + 1] = b
  end
  function bar:Select(key)
    self.selected = key
    for _, b in ipairs(self.buttons) do
      local on = b.key == key
      b.under:SetShown(on)
      b.text:SetTextColor(unpack(on and UI.C.ink or UI.C.muted))
    end
    onSelect(key)
  end
  return bar
end

-- A movable window with a title bar and a close button. Escape closes it.
function UI.Window(name, w, h, title)
  local f = CreateFrame("Frame", name, UIParent)
  f:SetSize(w, h)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  UI.Bg(f, UI.C.bg)
  UI.Border(f)
  local bar = CreateFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT"); bar:SetPoint("TOPRIGHT")
  bar:SetHeight(34)
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  local coin = bar:CreateTexture(nil, "ARTWORK")
  coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
  coin:SetSize(14, 14)
  coin:SetPoint("LEFT", 12, 0)
  f.title = UI.Text(bar, 15, "ink", "LEFT", UI.FONT_TITLE)
  f.title:SetPoint("LEFT", coin, "RIGHT", 8, 0)
  f.title:SetText(title)
  f.sub = UI.Text(bar, 12, "muted", "RIGHT")
  f.sub:SetPoint("RIGHT", -40, 0)
  local close = CreateFrame("Button", nil, bar)
  close:SetSize(26, 26)
  close:SetPoint("RIGHT", -6, 0)
  close.t = UI.Text(close, 18, "muted", "CENTER")
  close.t:SetPoint("CENTER", 0, 1)
  close.t:SetText("x")
  close:SetScript("OnEnter", function(self) self.t:SetTextColor(unpack(UI.C.ink)) end)
  close:SetScript("OnLeave", function(self) self.t:SetTextColor(unpack(UI.C.muted)) end)
  close:SetScript("OnClick", function() f:Hide() end)
  local rule = f:CreateTexture(nil, "BORDER")
  UI.Fill(rule, UI.C.line)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 0, -34); rule:SetPoint("TOPRIGHT", 0, -34)
  if name then tinsert(UISpecialFrames, name) end
  f:Hide()
  return f
end

---------------------------------------------------------------------------
-- Table: header that sorts, pooled rows, mouse-wheel scrolling, selectable rows
---------------------------------------------------------------------------
-- cols = { { key, label, width (0 = fill), align, render = function(row) -> text } }
-- opts = { rowHeight, onClick(row, data), onEnter(row, data), sortKey, sortDir }
function UI.Table(parent, cols, opts)
  opts = opts or {}
  local rh = opts.rowHeight or 22
  local t = CreateFrame("Frame", nil, parent)
  UI.Bg(t, UI.C.panel)
  UI.Border(t)
  t.cols, t.data, t.offset, t.rows = cols, {}, 0, {}
  t.sortKey, t.sortDir = opts.sortKey, opts.sortDir or -1

  local header = CreateFrame("Frame", nil, t)
  header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1)
  header:SetHeight(24)
  UI.Bg(header, UI.C.panel2)
  t.header = header

  local function Layout(frame, makeCell)
    local fixed, fills = 0, 0
    for _, c in ipairs(cols) do if c.width and c.width > 0 then fixed = fixed + c.width else fills = fills + 1 end end
    local avail = math.max(40, (t:GetWidth() - 2 - 16 - fixed) / math.max(1, fills))
    local x = 8
    for i, c in ipairs(cols) do
      local w = (c.width and c.width > 0) and c.width or avail
      local cell = makeCell(frame, i, c)
      cell:ClearAllPoints()
      cell:SetPoint("LEFT", frame, "LEFT", x, 0)
      cell:SetWidth(w - 8)
      x = x + w
    end
  end

  header.cells = {}
  local function HeaderCell(frame, i, c)
    local b = header.cells[i]
    if not b then
      b = CreateFrame("Button", nil, header)
      b:SetHeight(24)
      b.text = UI.Text(b, 12, "muted", c.align or "LEFT")
      b.text:SetAllPoints()
      b:SetScript("OnClick", function()
        if c.sort == false then return end
        if t.sortKey == c.key then t.sortDir = -t.sortDir else t.sortKey, t.sortDir = c.key, (c.align == "LEFT" or not c.align) and 1 or -1 end
        t:Refresh()
      end)
      header.cells[i] = b
    end
    return b
  end

  local function RowCell(frame, i, c)
    frame.cells[i] = frame.cells[i] or UI.Text(frame, 13, "ink", c.align or "LEFT")
    return frame.cells[i]
  end

  local function MakeRow(i)
    local r = CreateFrame("Button", nil, t)
    r:SetHeight(rh)
    r:SetPoint("TOPLEFT", 1, -25 - (i - 1) * rh)
    r:SetPoint("TOPRIGHT", -15, -25 - (i - 1) * rh)
    r.cells = {}
    r.stripe = r:CreateTexture(nil, "BACKGROUND")
    r.stripe:SetAllPoints()
    r.stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.025 or 0)
    r.sel = r:CreateTexture(nil, "BORDER")
    r.sel:SetAllPoints()
    UI.Fill(r.sel, { UI.C.brass[1], UI.C.brass[2], UI.C.brass[3], 0.18 })
    r.sel:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    r:SetScript("OnClick", function(self, btn) if self.data and opts.onClick then opts.onClick(self, self.data, btn) end end)
    r:SetScript("OnEnter", function(self) if self.data and opts.onEnter then opts.onEnter(self, self.data) end end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return r
  end

  -- scroll bar: a thin brass thumb on the right
  local track = CreateFrame("Frame", nil, t)
  track:SetPoint("TOPRIGHT", -3, -27); track:SetPoint("BOTTOMRIGHT", -3, 3)
  track:SetWidth(8)
  local thumb = track:CreateTexture(nil, "ARTWORK")
  UI.Fill(thumb, { UI.C.brass[1], UI.C.brass[2], UI.C.brass[3], 0.6 })
  thumb:SetWidth(4)
  t.thumb, t.track = thumb, track

  t.empty = UI.Text(t, 13, "muted", "CENTER")
  t.empty:SetPoint("TOP", 0, -60)
  t.empty:SetWidth(360)
  t.empty:SetWordWrap(true)

  function t:Visible() return math.max(1, math.floor((self:GetHeight() - 27) / rh)) end

  function t:SetData(list, emptyText)
    self.data = list or {}
    self.emptyText = emptyText
    self.offset = math.min(self.offset, math.max(0, #self.data - self:Visible()))
    self:Refresh()
  end

  function t:Refresh()
    Layout(header, HeaderCell)
    for i, c in ipairs(cols) do
      local arrow = (t.sortKey == c.key) and (t.sortDir < 0 and " v" or " ^") or ""
      header.cells[i].text:SetText(c.label .. arrow)
    end
    local key, dir = self.sortKey, self.sortDir
    if key then
      local col
      for _, c in ipairs(cols) do if c.key == key then col = c end end
      table.sort(self.data, function(a, b)
        local x, y = a[key], b[key]
        if col and col.sortValue then x, y = col.sortValue(a), col.sortValue(b) end
        if x == y then return false end
        if x == nil then return false elseif y == nil then return true end
        if type(x) == "string" then return (dir > 0) == (x:lower() < y:lower()) end
        return (dir > 0) == (x < y)
      end)
    end
    local n = self:Visible()
    for i = 1, n do
      local r = self.rows[i] or MakeRow(i)
      self.rows[i] = r
      local d = self.data[self.offset + i]
      r.data = d
      r:SetShown(d ~= nil)
      if d then
        Layout(r, RowCell)
        for ci, c in ipairs(cols) do r.cells[ci]:SetText(c.render and c.render(d) or tostring(d[c.key] or "")) end
        r.sel:SetShown(self.selected ~= nil and self.selected == d)
      end
    end
    for i = n + 1, #self.rows do self.rows[i]:Hide() end
    local total = #self.data
    if total > n then
      local h = track:GetHeight()
      thumb:SetHeight(math.max(16, h * n / total))
      thumb:ClearAllPoints()
      thumb:SetPoint("TOP", track, "TOP", 0, -(h - thumb:GetHeight()) * self.offset / (total - n))
      thumb:Show()
    else
      thumb:Hide()
    end
    self.empty:SetText(total == 0 and (self.emptyText or "") or "")
  end

  function t:Select(d) self.selected = d; self:Refresh() end

  t:EnableMouseWheel(true)
  t:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, math.min(self.offset - delta * 3, #self.data - self:Visible()))
    self:Refresh()
  end)
  t:SetScript("OnSizeChanged", function(self) self:Refresh() end)
  return t
end

-- item tooltip for a table row
function UI.ItemTooltip(owner, itemID)
  if not itemID then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(itemID)
  GameTooltip:Show()
end
