-- One line in item tooltips: the auction price, the Gold Board's way. That's the cheapest listing
-- now (Auctionator's last scan or the last TSM update, whichever is newer), never above what the item usually sells
-- for. Auctionator's own auction price line is switched off once, so there's a single price.

local _, GB = ...

-- what it would sell for at the auction house right now, per item
function GB.AuctionPrice(itemID)
  local s = GB.Signals.Get(itemID)
  local cheapest = GB.Pricing.Cheapest(itemID, s)
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
  tooltip:AddDoubleLine("Auction price", GB.UI.Money(price), 0.878, 0.706, 0.298, 0.925, 0.894, 0.824)
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
