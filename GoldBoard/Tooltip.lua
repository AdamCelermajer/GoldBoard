-- Gold Board lines in item tooltips: what it sells for, the buy-below price and the trend from the
-- dashboard, and what you paid for the ones you hold.

local _, GB = ...

local function Add(tooltip, data)
  if not GB.db or not GB.db.settings.tooltip then return end
  local itemID = data and GB.Clean(data.id)
  if not itemID and tooltip.GetItem then
    local _, link = tooltip:GetItem()
    itemID = GB.ItemIDFromLink(GB.Clean(link))
  end
  if not itemID then return end
  local s = GB.Signals.Get(itemID)
  local basis = GB.Ledger.CostBasis(itemID)
  if not s and not basis then return end
  tooltip:AddLine(" ")
  if s then
    local trend = ""
    if s.trend and math.abs(s.trend) >= 3 then
      trend = string.format(s.trend < 0 and "  |cff5cc4ad%d%% today|r" or "  |cffef7a5c+%d%% today|r", s.trend)
    end
    tooltip:AddDoubleLine("|cffe6bb52Gold Board|r sells for", GB.Money(s.sell) .. trend, 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine("  buy below", GB.Money(s.buyBelow), 0.8, 0.8, 0.8, 1, 1, 1)
    if s.soldPerDay then tooltip:AddDoubleLine("  sold a day (EU)", string.format("%.1f", s.soldPerDay), 0.8, 0.8, 0.8, 1, 1, 1) end
  end
  if basis then
    local line = string.format("%d held, paid %s each", basis.held, GB.Money(basis.avg))
    local r, g, b = 1, 1, 1
    -- what you could sell at now: the cheapest listing, never above what it usually sells for
    local now = s and s.sell and ((s.minBuy or 0) > 0 and math.min(s.sell, s.minBuy) or s.sell)
    if now then
      local gain = now * 0.95 - basis.avg
      line = line .. string.format(" (%s%s now)", gain >= 0 and "+" or "", GB.Money(gain))
      if gain >= 0 then r, g, b = 0.36, 0.77, 0.68 else r, g, b = 0.94, 0.48, 0.36 end
    end
    tooltip:AddLine("  " .. line, r, g, b)
  end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then pcall(Add, tooltip, data) end
  end)
else
  GameTooltip:HookScript("OnTooltipSetItem", function(tooltip) pcall(Add, tooltip, nil) end)
  ItemRefTooltip:HookScript("OnTooltipSetItem", function(tooltip) pcall(Add, tooltip, nil) end)
end
