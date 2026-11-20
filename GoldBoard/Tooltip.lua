-- One line in item tooltips: the auction price, the Gold Board's way. That's the cheapest listing
-- now (Auctionator's last scan, else the last TSM update), never above what the item usually sells
-- for. Auctionator's own auction price line is switched off once, so there's a single price.

local _, GB = ...

local function AuctionatorPrice(id)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID
  if not api then return nil end
  local ok, p = pcall(api, "Gold Board", id)
  return ok and p and p > 0 and p or nil
end

-- what it would sell for at the auction house right now, per item
function GB.AuctionPrice(itemID)
  local s = GB.Signals.Get(itemID)
  local cheapest = AuctionatorPrice(itemID) or (s and s.minBuy and s.minBuy > 0 and s.minBuy) or nil
  local usual = s and s.sell
  if cheapest and usual then return math.min(cheapest, usual) end
  return cheapest or usual
end

local function Add(tooltip, data)
  local itemID = data and GB.Clean(data.id)
  if not itemID and tooltip.GetItem then
    local _, link = tooltip:GetItem()
    itemID = GB.ItemIDFromLink(GB.Clean(link))
  end
  local price = itemID and GB.AuctionPrice(itemID)
  if not price then return end
  tooltip:AddDoubleLine("Auction price", GB.UI.Money(price), 0.85, 0.67, 0.31, 1, 1, 1)
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then pcall(Add, tooltip, data) end
  end)
else
  GameTooltip:HookScript("OnTooltipSetItem", function(tooltip) pcall(Add, tooltip, nil) end)
  ItemRefTooltip:HookScript("OnTooltipSetItem", function(tooltip) pcall(Add, tooltip, nil) end)
end

-- Auctionator's auction price line off, once (you can turn it back on in Auctionator's options)
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  if GB.db.settings.auctionatorTooltipOff then return end
  local cfg = Auctionator and Auctionator.Config
  if cfg and cfg.Set and cfg.Options and cfg.Options.AUCTION_TOOLTIPS then
    if pcall(cfg.Set, cfg.Options.AUCTION_TOOLTIPS, false) then GB.db.settings.auctionatorTooltipOff = true end
  end
end)
