-- Gold Board's look, shared with the dashboard: warm charcoal panels, gold for what matters, green for
-- "cheap / profit / do it" and red for "dear / loss / don't", off-white text. Every window is built from
-- these few parts so they all look the same. Only plain textures, lines and font strings are used.

local _, GB = ...
local UI = {}
GB.UI = UI

UI.C = {
  bg      = { 0.071, 0.063, 0.051, 1 },     -- #12100d  window (opaque: nothing of the world shows through)
  panel   = { 0.102, 0.090, 0.075, 1 },     -- #1a1713  tables, cards
  panel2  = { 0.141, 0.125, 0.102, 1 },     -- #24201a  title bar, table header, buttons
  panel3  = { 0.192, 0.169, 0.133, 1 },     -- #312b22  hovered button
  line    = { 0.227, 0.200, 0.157, 1 },     -- #3a3328  borders, rules
  ink     = { 0.925, 0.894, 0.824, 1 },     -- #ece4d2  text
  muted   = { 0.655, 0.616, 0.537, 1 },     -- #a79d89  secondary text
  faint   = { 0.467, 0.435, 0.373, 1 },     -- #776f5f  hints, disabled
  gold    = { 0.878, 0.706, 0.298, 1 },     -- #e0b44c  the accent
  buy     = { 0.435, 0.749, 0.451, 1 },     -- #6fbf73  cheap, profit, sell now
  sell    = { 0.878, 0.396, 0.353, 1 },     -- #e0655a  dear, loss, hold
  dark    = { 0.090, 0.075, 0.047, 1 },     -- #17130c  text on gold
}
UI.C.brass = UI.C.gold   -- the accent's old name
UI.HEX = { ink = "ece4d2", muted = "a79d89", faint = "776f5f", gold = "e0b44c", brass = "e0b44c", buy = "6fbf73", sell = "e0655a" }
function UI.Color(name, text) return "|cff" .. (UI.HEX[name] or UI.HEX.ink) .. text .. "|r" end

UI.FONT_TEXT = "Fonts\\ARIALN.TTF"      -- condensed: numbers, tables, labels
UI.FONT_TITLE = "Fonts\\FRIZQT__.TTF"   -- the game's own face, for titles

UI.PAD = 14          -- space between a window's edge and what's in it
UI.HEAD = 36         -- title bar height
UI.TABS = 30         -- tab row height
UI.TOP = UI.HEAD + UI.TABS + 1   -- where a window's body starts

local function Fill(tex, c, a) tex:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1) end
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
  function f:SetBorderColor(col) for _, t in ipairs(self.borders) do Fill(t, col) end end
end

function UI.Bg(f, c, layer)
  local t = f:CreateTexture(nil, layer or "BACKGROUND")
  Fill(t, c or UI.C.panel)
  t:SetAllPoints()
  return t
end

-- a horizontal 1-pixel rule across a frame, y pixels from its top
function UI.Rule(f, y, c, inset)
  local t = f:CreateTexture(nil, "BORDER")
  Fill(t, c or UI.C.line)
  t:SetHeight(1)
  t:SetPoint("TOPLEFT", inset or 0, y); t:SetPoint("TOPRIGHT", -(inset or 0), y)
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

-- a paragraph: wraps inside its width
function UI.Note(parent, width, color, size)
  local fs = UI.Text(parent, size or 12, color or "muted")
  fs:SetWidth(width)
  fs:SetWordWrap(true)
  fs:SetJustifyV("TOP")
  fs:SetSpacing(2)
  return fs
end

-- Money with the game's coin icons: 12g 34s 56c (silver and copper dropped where they don't matter)
function UI.Money(c, opts)
  c = GB.Clean(c)
  if not c then return UI.Color("faint", "-") end
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
  if not v or v ~= v then return UI.Color("faint", "-") end
  return string.format("%s%d%%", (signed ~= false and v > 0) and "+" or "", math.floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
end

-- a verdict, the word in its color ("Sell now" green, "Wait" gold, "Hold" red)
function UI.Verdict(color, text) return UI.Color(color, text) end

-- item name in its quality color, with its icon
function UI.ItemText(itemID, fallback)
  local name = itemID and (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or fallback or "?"
  local q = itemID and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)
  local icon = itemID and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
  local color = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] and ITEM_QUALITY_COLORS[q].hex or ("|cff" .. UI.HEX.ink)
  return (icon and ("|T" .. icon .. ":16:16:0:0:64:64:5:59:5:59|t ") or "") .. color .. (name or fallback or "?") .. "|r"
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

-- kind: "primary" (gold, the one action that matters), "normal", "quiet" (no border, for secondary actions)
function UI.Button(parent, label, w, h, kind)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w or 100, h or 26)
  b.kind = kind or "normal"
  local base = b.kind == "primary" and UI.C.gold or b.kind == "quiet" and UI.C.panel or UI.C.panel2
  local over = b.kind == "primary" and { 0.95, 0.79, 0.40, 1 } or UI.C.panel3
  b.bg = UI.Bg(b, base, "BACKGROUND")
  UI.Border(b, b.kind == "primary" and UI.C.gold or UI.C.line)
  b.text = UI.Text(b, 13, b.kind == "primary" and UI.C.dark or b.kind == "quiet" and "muted" or "ink", "CENTER")
  b.text:SetPoint("LEFT", 8, 0); b.text:SetPoint("RIGHT", -8, 0)
  b.text:SetText(label)
  function b:SetLabel(t) self.text:SetText(t) end
  -- a click that fails says so in chat (with its file and line) instead of doing nothing
  local setScript = b.SetScript
  function b:SetScript(name, fn)
    if name == "OnClick" and fn then fn = GB.Safe(fn, label) end
    return setScript(self, name, fn)
  end
  -- For a click that ends in a call the game only takes straight from a real click (post, buy, cancel).
  -- prepare() does the checking and returns the one call to make and what to do after it. The call itself
  -- runs directly in the click handler, with nothing wrapped around it and nothing changed on screen first.
  -- arm(entry), if given, runs just before the call: it only sets state and registers events (nothing is
  -- redrawn), so an answer the game gives during the call itself is heard.
  function b:SetAction(prepare, where)
    setScript(self, "OnClick", function()
      local ok, act, after, call, arm = pcall(prepare)
      if not ok then GB.Report(act, where or label) return end
      if type(act) ~= "function" then return end
      local entry = GB.CallStarted(where or label, call)
      GB.blockedNow = nil
      if arm then
        local okArm, errArm = pcall(arm, entry)
        if not okArm then GB.Report(errArm, where or label) return end
      end
      local result = act()
      GB.CallReturned(entry, result)
      local blocked = GB.blockedNow      -- the function the game refused, if it refused this very call
      if after then
        local ok2, err = pcall(after, result, blocked, entry)
        if not ok2 then GB.Report(err, where or label) end
      end
    end)
  end
  b:SetScript("OnEnter", function(self)
    if not self:IsEnabled() then return end
    Fill(self.bg, over)
    if self.kind ~= "primary" then self:SetBorderColor(UI.C.gold) end
  end)
  b:SetScript("OnLeave", function(self)
    Fill(self.bg, base)
    if self.kind ~= "primary" then self:SetBorderColor(UI.C.line) end
  end)
  b:SetScript("OnEnable", function(self) self:SetAlpha(1) end)
  b:SetScript("OnDisable", function(self)
    self:SetAlpha(0.4)
    Fill(self.bg, base)
    if self.kind ~= "primary" then self:SetBorderColor(UI.C.line) end
  end)
  return b
end

function UI.Input(parent, w, placeholder)
  local e = CreateFrame("EditBox", nil, parent)
  e:SetSize(w or 160, 26)
  e:SetAutoFocus(false)
  e:SetFont(UI.FONT_TEXT, 13, "")
  e:SetTextColor(unpack(UI.C.ink))
  e:SetTextInsets(9, 9, 0, 0)
  UI.Bg(e, UI.C.panel)
  UI.Border(e)
  e.hint = UI.Text(e, 13, "faint")
  e.hint:SetPoint("LEFT", 9, 0)
  e.hint:SetText(placeholder or "")
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEditFocusGained", function(self) self:SetBorderColor(UI.C.gold) end)
  e:SetScript("OnEditFocusLost", function(self) self:SetBorderColor(UI.C.line) end)
  e:HookScript("OnTextChanged", function(self) self.hint:SetShown(self:GetText() == "") end)
  return e
end

-- a row of tabs; onSelect(key). The chosen tab is off-white with a gold bar under it.
function UI.Tabs(parent, items, onSelect)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetHeight(UI.TABS)
  bar.buttons = {}
  local x = 0
  for _, it in ipairs(items) do
    local b = CreateFrame("Button", nil, bar)
    b.key = it.key
    b.text = UI.Text(b, 13, "muted", "CENTER", UI.FONT_TITLE)
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(it.label)
    b:SetSize(math.max(60, b.text:GetStringWidth() + 26), UI.TABS)
    b:SetPoint("LEFT", x, 0)
    x = x + b:GetWidth() + 2
    b.under = b:CreateTexture(nil, "ARTWORK")
    Fill(b.under, UI.C.gold)
    b.under:SetHeight(2)
    b.under:SetPoint("BOTTOMLEFT", 6, 0)
    b.under:SetPoint("BOTTOMRIGHT", -6, 0)
    b:SetScript("OnClick", function() bar:Select(it.key) end)
    b:SetScript("OnEnter", function(self) if bar.selected ~= self.key then self.text:SetTextColor(unpack(UI.C.ink)) end end)
    b:SetScript("OnLeave", function(self) if bar.selected ~= self.key then self.text:SetTextColor(unpack(UI.C.muted)) end end)
    bar.buttons[#bar.buttons + 1] = b
  end
  function bar:Has(key)
    for _, b in ipairs(self.buttons) do if b.key == key then return true end end
    return false
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

-- Where a dragged frame ends up, saved as a point on the screen; RestorePosition puts it back.
function UI.SavePosition(f, key)
  local point, _, rel, x, y = f:GetPoint(1)
  if point then GB.db.settings[key] = { point, rel, x, y } end
end
function UI.RestorePosition(f, key)
  local p = GB.db.settings[key]
  if type(p) ~= "table" or not p[1] then return false end
  f:ClearAllPoints()
  f:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
  return true
end

-- A movable window: title bar (coin, title, a line of status on the right, close button), a gold hairline
-- under it. saveKey: remember where you drag it.
-- opts: parent, escape (false = Escape doesn't close it), onClose, onRightClick + hint (title bar tooltip)
function UI.Window(name, w, h, title, saveKey, opts)
  opts = opts or {}
  local f = CreateFrame("Frame", name, opts.parent or UIParent)
  f:SetSize(w, h)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  UI.Bg(f, UI.C.bg)
  UI.Border(f)
  local bar = CreateFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("TOPRIGHT", -1, -1)
  bar:SetHeight(UI.HEAD - 1)
  UI.Bg(bar, UI.C.panel2)
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  bar:SetScript("OnDragStop", function() f:StopMovingOrSizing(); if saveKey then UI.SavePosition(f, saveKey) end end)
  if opts.onRightClick then
    bar:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then opts.onRightClick() end end)
  end
  if opts.hint then
    bar:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(opts.hint, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  local coin = bar:CreateTexture(nil, "ARTWORK")
  coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
  coin:SetSize(15, 15)
  coin:SetPoint("LEFT", UI.PAD - 1, 0)
  f.title = UI.Text(bar, 15, "gold", "LEFT", UI.FONT_TITLE)
  f.title:SetPoint("LEFT", coin, "RIGHT", 8, 0)
  f.title:SetText(title)
  f.sub = UI.Text(bar, 12, "muted", "RIGHT")
  f.sub:SetPoint("RIGHT", -40, 0)
  f.sub:SetPoint("LEFT", f.title, "RIGHT", 16, 0)
  local close = CreateFrame("Button", nil, bar)
  close:SetSize(28, 28)
  close:SetPoint("RIGHT", -4, 0)
  -- an X from two lines (no font needed)
  close.a, close.b = close:CreateLine(nil, "ARTWORK"), close:CreateLine(nil, "ARTWORK")
  close.a:SetStartPoint("CENTER", close, -5, 5); close.a:SetEndPoint("CENTER", close, 5, -5)
  close.b:SetStartPoint("CENTER", close, -5, -5); close.b:SetEndPoint("CENTER", close, 5, 5)
  local function Tint(c) for _, l in ipairs({ close.a, close.b }) do l:SetColorTexture(c[1], c[2], c[3], 1); l:SetThickness(1.5) end end
  Tint(UI.C.muted)
  close:SetScript("OnEnter", function() Tint(UI.C.sell) end)
  close:SetScript("OnLeave", function() Tint(UI.C.muted) end)
  close:SetScript("OnClick", function() f:Hide(); if opts.onClose then opts.onClose() end end)
  local rule = f:CreateTexture(nil, "ARTWORK")
  Fill(rule, UI.C.gold, 0.55)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 1, -UI.HEAD); rule:SetPoint("TOPRIGHT", -1, -UI.HEAD)
  if name and opts.escape ~= false then tinsert(UISpecialFrames, name) end
  f:Hide()
  return f
end

---------------------------------------------------------------------------
-- The order of two cells, one rule for every table (the game stops a sort whose order contradicts itself):
-- empty and NaN last in either direction, text without regard to case, mixed kinds compared as text.
-- Everything is made comparable first, so "equal" is decided on the same values the order is.
function UI.SortLess(x, y, dir)
  if x ~= x then x = nil end
  if y ~= y then y = nil end
  if x == nil or y == nil then return x ~= nil and y == nil end
  if type(x) ~= type(y) or (type(x) ~= "number" and type(x) ~= "string") then x, y = tostring(x), tostring(y) end
  if type(x) == "string" then x, y = x:lower(), y:lower() end
  if x == y then return false end
  if dir > 0 then return x < y end
  return y < x
end

-- Table: header that sorts, pooled rows, mouse-wheel scrolling, selectable rows
---------------------------------------------------------------------------
-- cols = { { key, label, width (0 = fill), align, render = function(row) -> text, sort = false, sortValue } }
-- opts = { rowHeight, onClick(row, data), onEnter(row, data), sortKey, sortDir }
-- t:SetData(list, emptyText, tone)  tone "error" shows the empty text in red
local HEADER_H = 26

function UI.Table(parent, cols, opts)
  opts = opts or {}
  local rh = opts.rowHeight or 24
  local t = CreateFrame("Frame", nil, parent)
  UI.Bg(t, UI.C.panel)
  UI.Border(t)
  t.cols, t.data, t.offset, t.rows = cols, {}, 0, {}
  t.sortKey, t.sortDir = opts.sortKey, opts.sortDir or -1

  local header = CreateFrame("Frame", nil, t)
  header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1)
  header:SetHeight(HEADER_H)
  UI.Bg(header, UI.C.panel2)
  UI.Rule(header, -HEADER_H, UI.C.line)
  t.header = header

  local function Layout(frame, makeCell)
    local fixed, fills = 0, 0
    for _, c in ipairs(cols) do if c.width and c.width > 0 then fixed = fixed + c.width else fills = fills + 1 end end
    local avail = math.max(40, (t:GetWidth() - 2 - 20 - fixed) / math.max(1, fills))
    local x = 10
    for i, c in ipairs(cols) do
      local w = (c.width and c.width > 0) and c.width or avail
      local cell = makeCell(frame, i, c)
      cell:ClearAllPoints()
      cell:SetPoint("LEFT", frame, "LEFT", x, 0)
      cell:SetWidth(w - 10)
      x = x + w
    end
  end

  header.cells = {}
  local function HeaderCell(frame, i, c)
    local b = header.cells[i]
    if not b then
      b = CreateFrame("Button", nil, header)
      b:SetHeight(HEADER_H)
      b.text = UI.Text(b, 12, "muted", c.align or "LEFT")
      b.text:SetAllPoints()
      -- a small gold chevron beside the sorted column's label, drawn from two lines
      b.arrow = CreateFrame("Frame", nil, b)
      b.arrow:SetSize(8, 5)
      b.arrow.a, b.arrow.b = b.arrow:CreateLine(nil, "OVERLAY"), b.arrow:CreateLine(nil, "OVERLAY")
      for _, l in ipairs({ b.arrow.a, b.arrow.b }) do
        l:SetColorTexture(UI.C.gold[1], UI.C.gold[2], UI.C.gold[3], 1)
        l:SetThickness(1.5)
      end
      function b.arrow:Point(down)
        local tip, base = down and "BOTTOM" or "TOP", down and "TOP" or "BOTTOM"
        self.a:SetStartPoint(base .. "LEFT", self, 0, 0); self.a:SetEndPoint(tip, self, 0, 0)
        self.b:SetStartPoint(base .. "RIGHT", self, 0, 0); self.b:SetEndPoint(tip, self, 0, 0)
      end
      b.arrow:Hide()
      b:SetScript("OnClick", function()
        if c.sort == false then return end
        if t.sortKey == c.key then t.sortDir = -t.sortDir else t.sortKey, t.sortDir = c.key, (c.align == "LEFT" or not c.align) and 1 or -1 end
        t:Refresh()
      end)
      if c.sort ~= false then
        b:SetScript("OnEnter", function(self) if t.sortKey ~= c.key then self.text:SetTextColor(unpack(UI.C.ink)) end end)
        b:SetScript("OnLeave", function(self) if t.sortKey ~= c.key then self.text:SetTextColor(unpack(UI.C.muted)) end end)
      end
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
    r:SetPoint("TOPLEFT", 1, -(HEADER_H + 2) - (i - 1) * rh)
    r:SetPoint("TOPRIGHT", -12, -(HEADER_H + 2) - (i - 1) * rh)
    r.cells = {}
    r.stripe = r:CreateTexture(nil, "BACKGROUND")
    r.stripe:SetAllPoints()
    r.stripe:SetColorTexture(1, 0.93, 0.78, i % 2 == 0 and 0.03 or 0)
    r.sel = r:CreateTexture(nil, "BORDER")
    r.sel:SetAllPoints()
    Fill(r.sel, UI.C.gold, 0.14)
    r.sel:Hide()
    r.selBar = r:CreateTexture(nil, "ARTWORK")
    Fill(r.selBar, UI.C.gold)
    r.selBar:SetWidth(2)
    r.selBar:SetPoint("TOPLEFT"); r.selBar:SetPoint("BOTTOMLEFT")
    r.selBar:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.93, 0.78, 0.07)
    r:SetScript("OnClick", GB.Safe(function(self, btn) if self.data and opts.onClick then opts.onClick(self, self.data, btn) end end, "row click"))
    r:SetScript("OnEnter", GB.Safe(function(self) if self.data and opts.onEnter then opts.onEnter(self, self.data) end end, "row tooltip"))
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return r
  end

  -- scroll bar: a thin gold thumb on the right
  local track = CreateFrame("Frame", nil, t)
  track:SetPoint("TOPRIGHT", -4, -(HEADER_H + 4)); track:SetPoint("BOTTOMRIGHT", -4, 4)
  track:SetWidth(4)
  local thumb = track:CreateTexture(nil, "ARTWORK")
  Fill(thumb, UI.C.gold, 0.55)
  thumb:SetWidth(4)
  t.thumb, t.track = thumb, track

  t.empty = UI.Note(t, 380, "muted", 13)
  t.empty:SetJustifyH("CENTER")
  t.empty:SetPoint("TOP", 0, -(HEADER_H + 38))

  function t:Visible() return math.max(1, math.floor((self:GetHeight() - HEADER_H - 4) / rh)) end

  function t:SetData(list, emptyText, tone)
    self.data = list or {}
    self.emptyText, self.emptyTone = emptyText, tone
    self.offset = math.min(self.offset, math.max(0, #self.data - self:Visible()))
    self:Refresh()
  end

  function t:Refresh()
    Layout(header, HeaderCell)
    for i, c in ipairs(cols) do
      local on = t.sortKey == c.key
      local cell = header.cells[i]
      -- the sorted column's label turns gold with an arrow beside it (down = biggest first)
      cell.text:SetText(c.label)
      cell.text:SetTextColor(unpack(on and UI.C.gold or UI.C.muted))
      cell.arrow:SetShown(on)
      if on then
        cell.arrow:ClearAllPoints()
        if c.align == "RIGHT" then
          cell.arrow:SetPoint("RIGHT", cell, "RIGHT", -(cell.text:GetStringWidth() + 5), 0)
        else
          cell.arrow:SetPoint("LEFT", cell, "LEFT", cell.text:GetStringWidth() + 5, 0)
        end
        cell.arrow:Point(t.sortDir < 0)
      end
    end
    local key, dir = self.sortKey, self.sortDir
    if key then
      local col
      for _, c in ipairs(cols) do if c.key == key then col = c end end
      table.sort(self.data, function(a, b)
        local x, y = a[key], b[key]
        if col and col.sortValue then x, y = col.sortValue(a), col.sortValue(b) end
        return UI.SortLess(x, y, dir)
      end)
    end
    local n = self:Visible()
    self.offset = math.max(0, math.min(self.offset, #self.data - n))
    for i = 1, n do
      local r = self.rows[i] or MakeRow(i)
      self.rows[i] = r
      local d = self.data[self.offset + i]
      r.data = d
      r:SetShown(d ~= nil)
      if d then
        Layout(r, RowCell)
        for ci, c in ipairs(cols) do r.cells[ci]:SetText(c.render and c.render(d) or tostring(d[c.key] or "")) end
        local on = self.selected ~= nil and self.selected == d
        r.sel:SetShown(on)
        r.selBar:SetShown(on)
      end
    end
    for i = n + 1, #self.rows do self.rows[i]:Hide() end
    local total = #self.data
    if total > n then
      local h = track:GetHeight()
      thumb:SetHeight(math.max(18, h * n / total))
      thumb:ClearAllPoints()
      thumb:SetPoint("TOP", track, "TOP", 0, -(h - thumb:GetHeight()) * self.offset / (total - n))
      thumb:Show()
    else
      thumb:Hide()
    end
    self.empty:SetText(total == 0 and (self.emptyText or "") or "")
    self.empty:SetTextColor(unpack(self.emptyTone == "error" and UI.C.sell or UI.C.muted))
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
