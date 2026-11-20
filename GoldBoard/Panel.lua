-- A small panel beside the auction house: what you hold that's worth selling now, and the best
-- buys at the last TSM update. Clicking a row searches for it in Auctionator (you still buy and post
-- yourself). /gb shows or hides it.

local _, GB = ...
local P = {}
GB.Panel = P

local ROWS = 8
local WIDTH = 290
local frame, sections

local function ItemName(itemID)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  return name or (GetItemInfo and GetItemInfo(itemID)) or ("item " .. itemID)
end

local function Search(itemID)
  local name = ItemName(itemID)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.MultiSearchExact
  if api and not name:find("^item ") then
    local ok = pcall(api, "Gold Board", { name })
    if ok then return end
  end
  GB.Print("search the auction house for: " .. name)
end

local function MakeRow(parent, y)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(WIDTH - 20, 18)
  b:SetPoint("TOPLEFT", 10, y)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.left:SetPoint("LEFT", 2, 0)
  b.left:SetWidth(WIDTH - 130)
  b.left:SetJustifyH("LEFT")
  b.left:SetWordWrap(false)
  b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.right:SetPoint("RIGHT", -2, 0)
  b.right:SetJustifyH("RIGHT")
  b:SetScript("OnClick", function(self) if self.itemID then Search(self.itemID) end end)
  b:SetScript("OnEnter", function(self)
    if not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemID)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function MakeSection(parent, title, y)
  local s = { rows = {} }
  s.title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  s.title:SetPoint("TOPLEFT", 12, y)
  s.title:SetText(title)
  s.empty = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  s.empty:SetPoint("TOPLEFT", 14, y - 20)
  s.empty:SetWidth(WIDTH - 28)
  s.empty:SetJustifyH("LEFT")
  for i = 1, ROWS do s.rows[i] = MakeRow(parent, y - 18 - (i - 1) * 18) end
  return s
end

local function Fill(s, list, emptyText)
  for i, row in ipairs(s.rows) do
    local e = list[i]
    row.itemID = e and e.itemID
    row:SetShown(e ~= nil)
    if e then
      row.left:SetText(ItemName(e.itemID))
      row.right:SetText(e.right)
    end
  end
  s.empty:SetText(#list == 0 and emptyText or "")
end

-- holdings with what they'd make now, after the 5% auction cut
local function SellList()
  local out, seen = {}, {}
  for _, e in ipairs(GB.db.ledger) do
    if e.kind == "buy" and e.itemID and not seen[e.itemID] then
      seen[e.itemID] = true
      local basis = GB.Ledger.CostBasis(e.itemID)
      local s = GB.Signals.Get(e.itemID)
      if basis and basis.held > 0 and s and s.sell then
        -- what you could sell at now: the cheapest listing, never above what it usually sells for
        local now = (s.minBuy or 0) > 0 and math.min(s.sell, s.minBuy) or s.sell
        local gain = (now * 0.95 - basis.avg) / basis.avg
        local color = gain >= 0.3 and "|cff5cc4ad" or gain >= 0 and "|cffffffff" or "|cffef7a5c"
        out[#out + 1] = { itemID = e.itemID, gain = gain,
          right = string.format("%dx  %s%+d%%|r", basis.held, color, math.floor(gain * 100 + 0.5)) }
      end
    end
  end
  table.sort(out, function(a, b) return a.gain > b.gain end)
  return out
end

-- cheapest listing under the buy-below price at the last TSM update, best value first
local function DealList()
  local out = {}
  for itemID, s in pairs(GB.Signals.All()) do
    if s.minBuy and s.buyBelow and s.sell and s.minBuy > 0 and s.minBuy <= s.buyBelow and (s.soldPerDay or 0) >= 2 then
      local profit = s.sell * 0.95 - s.minBuy
      out[#out + 1] = { itemID = itemID, score = profit * math.min(s.soldPerDay, 50),
        right = GB.Money(s.minBuy) .. " |cff5cc4ad+" .. GB.Money(profit):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r" }
    end
  end
  table.sort(out, function(a, b) return a.score > b.score end)
  return out
end

local function Build()
  local parent = AuctionFrame or UIParent
  frame = CreateFrame("Frame", "GoldBoardPanel", parent, "BackdropTemplate")
  frame:SetSize(WIDTH, 62 + 2 * (ROWS * 18 + 30))
  if AuctionFrame then frame:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", 4, -12) else frame:SetPoint("CENTER") end
  frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  frame:SetBackdropColor(0.06, 0.15, 0.19, 0.95)
  frame:SetBackdropBorderColor(0.85, 0.67, 0.31, 1)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.title:SetPoint("TOPLEFT", 12, -10)
  frame.title:SetText("Gold Board")
  frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.sub:SetPoint("TOPLEFT", 12, -30)
  frame.sub:SetWidth(WIDTH - 24)
  frame.sub:SetJustifyH("LEFT")
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 0, 0)
  close:SetScript("OnClick", function() P.SetShown(false) end)
  sections = {
    sell = MakeSection(frame, "Your items: gain if sold now", -52),
    deals = MakeSection(frame, "Under buy-below at the last TSM update", -52 - (ROWS * 18 + 30)),
  }
end

function P.Refresh()
  if not frame or not frame:IsShown() then return end
  frame.sub:SetText(GB.Signals.Describe() .. ". Click a row to search it.")
  Fill(sections.sell, SellList(), "Nothing you bought at the auction house is held right now.")
  Fill(sections.deals, DealList(), "No signals loaded. Run the Gold Board on your PC, then /reload.")
end

function P.SetShown(show)
  GB.db.settings.panel = show
  if show and not frame then Build() end
  if frame then frame:SetShown(show and (not AuctionFrame or AuctionFrame:IsShown())) end
  P.Refresh()
end

function P.Toggle()
  P.SetShown(not (frame and frame:IsShown()))
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_SHOW" then
    GB.Ledger.RefreshHoldings()
    if GB.db.settings.panel then
      if not frame then Build() end
      frame:SetParent(AuctionFrame or UIParent)
      frame:ClearAllPoints()
      if AuctionFrame then frame:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", 4, -12) else frame:SetPoint("CENTER") end
      frame:Show()
      P.Refresh()
    end
  elseif frame then
    frame:Hide()
  end
end)
