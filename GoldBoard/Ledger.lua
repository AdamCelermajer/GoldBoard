-- The ledger: every auction house buy, sale, post, cancel and expiry, with what it cost or earned.
--
-- Sources, so nothing is guessed:
--   buys   : the bid you place (PlaceAuctionBid, whoever's UI calls it), confirmed by the game's
--            "You won an auction for X" message; a win you weren't online for is taken from its mail.
--   sales  : the "Auction successful" mail when you take its money (sale price, auction cut, deposit back).
--   expired / cancelled : their mails when you take the item back.
--   posts  : Auctionator's own "post successful" report (stack size, price, deposit).
-- Entries: { id, t, kind, char, ah, itemID, name, qty, price (total copper), cut, deposit, net, source }

local _, GB = ...
local L = {}
GB.Ledger = L

local MAIL_DAYS = 30   -- auction mails expire after 30 days: their send time is now - (30 - daysLeft) days

local function Add(entry)
  entry.id = GB.NextID()
  entry.t = entry.t or time()
  entry.char = GB.Character()
  entry.ah = GB.AH()
  if entry.name and entry.itemID then GB.LearnName(entry.name, entry.itemID) end
  entry.itemID = entry.itemID or GB.IDFromName(entry.name)
  GB.db.ledger[#GB.db.ledger + 1] = entry
  if GB.Panel and GB.Panel.Refresh then GB.Panel.Refresh() end
  return entry
end
L.Add = Add

-- "Auction won: %s" -> "^Auction won: (.+)$", from the game's own (localized) strings
local function Pattern(fmt)
  if not fmt then return nil end
  local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
  return "^" .. p .. "$"
end

-- "Linen Cloth (20)" -> "Linen Cloth", 20
local function SplitCount(name)
  local base, n = name:match("^(.-) %((%d+)%)$")
  if base then return base, tonumber(n) end
  return name, nil
end

---------------------------------------------------------------------------
-- Buys
---------------------------------------------------------------------------

local pending = {}   -- bids placed this session, waiting for the "you won" message

local function OnBid(listType, index, bid)
  local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo(listType, index)
  name, count, buyout, itemID, bid = GB.Clean(name), GB.Clean(count), GB.Clean(buyout), GB.Clean(itemID), GB.Clean(bid)
  if not name or not bid then return end
  pending[#pending + 1] = { t = time(), name = name, itemID = itemID, qty = count or 1, price = bid,
                            buyout = buyout and buyout > 0 and bid >= buyout }
end

local wonPattern
local function OnSystemMessage(msg)
  wonPattern = wonPattern or Pattern(ERR_AUCTION_WON_S)
  local name = wonPattern and msg and msg:match(wonPattern)
  if not name then return end
  for i, p in ipairs(pending) do
    if p.name == name then
      table.remove(pending, i)
      Add({ kind = "buy", t = p.t, itemID = p.itemID, name = p.name, qty = p.qty, price = p.price, source = "won" })
      return
    end
  end
end

-- A won-auction mail: already in the ledger (you were online when you won it) or a new buy.
local function RecordWonMail(index, name, count, bid, sentAt)
  local qty = count
  local base, n = SplitCount(name)
  name, qty = base, qty or n or 1
  for i = #GB.db.ledger, math.max(1, #GB.db.ledger - 300), -1 do
    local e = GB.db.ledger[i]
    if e.kind == "buy" and not e.mailed and e.name == name and e.price == bid and math.abs(e.t - sentAt) < 3 * 86400 then
      e.mailed = true
      return
    end
  end
  local link = GetInboxItemLink and GetInboxItemLink(index, 1)
  Add({ kind = "buy", t = sentAt, itemID = GB.ItemIDFromLink(link), name = name, qty = qty, price = bid,
        source = "mail", mailed = true })
end

---------------------------------------------------------------------------
-- Mail: sales, wins, expiries, cancellations
---------------------------------------------------------------------------

local patterns
local function MailKind(subject)
  patterns = patterns or {
    sell = Pattern(AUCTION_SOLD_MAIL_SUBJECT),
    won = Pattern(AUCTION_WON_MAIL_SUBJECT),
    expire = Pattern(AUCTION_EXPIRED_MAIL_SUBJECT),
    cancel = Pattern(AUCTION_REMOVED_MAIL_SUBJECT),
  }
  for kind, p in pairs(patterns) do
    local name = p and subject and subject:match(p)
    if name then return kind, name end
  end
end

local recorded = {}   -- mails handled this session (a double click must not count twice)

-- what: "money" (TakeInboxMoney), "item" (TakeInboxItem) or "all" (AutoLootMailItem, open-all addons)
local function OnMailTake(index, what)
  local _, _, sender, subject, money, _, daysLeft, itemCount = GetInboxHeaderInfo(index)
  local kind, subjectName = MailKind(subject)
  if not kind then return end
  local key = table.concat({ tostring(sender), tostring(subject), tostring(money), tostring(itemCount),
    string.format("%.3f", daysLeft or 0) }, "|")
  if recorded[key] then return end
  local sentAt = time() - math.floor((MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400)
  local invoiceType, itemName, _, bid, buyout, deposit, consignment, _, _, count = GetInboxInvoiceInfo(index)

  if kind == "sell" and (what == "money" or what == "all") then
    recorded[key] = true
    local name, n = SplitCount(itemName or subjectName)
    Add({ kind = "sell", t = sentAt, name = name, qty = count or n or 1, price = bid or 0, cut = consignment or 0,
          deposit = deposit or 0, net = money or 0, buyout = buyout, source = "mail" })
  elseif kind == "won" and (what == "item" or what == "all") then
    recorded[key] = true
    RecordWonMail(index, itemName or subjectName, count, bid or 0, sentAt)
  elseif (kind == "expire" or kind == "cancel") and (what == "item" or what == "all") then
    recorded[key] = true
    local link = GetInboxItemLink and GetInboxItemLink(index, 1)
    local _, _, _, n = GetInboxItem and GetInboxItem(index, 1)
    local name = SplitCount(subjectName)
    Add({ kind = kind, t = sentAt, itemID = GB.ItemIDFromLink(link), name = name, qty = n or 1, source = "mail" })
  end
end

---------------------------------------------------------------------------
-- Posts and cancels
---------------------------------------------------------------------------

local function OnPostSuccessful(details)
  if type(details) ~= "table" or type(details.itemInfo) ~= "table" then return end
  local link = details.itemInfo.itemLink
  local name = link and link:match("%[(.-)%]")
  Add({ kind = "post", itemID = GB.ItemIDFromLink(link), name = name, qty = (details.stackSize or 1) * (details.numStacks or 1),
        stacks = details.numStacks, stackSize = details.stackSize, price = details.buyoutPrice, unit = details.unitPrice,
        deposit = details.deposit, duration = details.duration, source = "auctionator" })
end

local function OnCancel(index)
  local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo("owner", index)
  if not GB.Clean(name) then return end
  Add({ kind = "cancel", itemID = itemID, name = name, qty = count or 1, price = buyout, source = "ah" })
end

---------------------------------------------------------------------------
-- Holdings (Syndicator counts every character's bags, bank and mail)
---------------------------------------------------------------------------

function L.RefreshHoldings()
  local api = Syndicator and Syndicator.API and Syndicator.API.GetInventoryInfoByItemID
  if not api then return end
  local seen = {}
  for _, e in ipairs(GB.db.ledger) do
    if e.kind == "buy" and e.itemID and not seen[e.itemID] then
      seen[e.itemID] = true
      local ok, info = pcall(api, e.itemID, false, false)
      if ok and type(info) == "table" then
        local total = 0
        for _, c in ipairs(info.characters or {}) do
          total = total + (c.bags or 0) + (c.bank or 0) + (c.mail or 0) + (c.equipped or 0) + (c.void or 0) + (c.auctions or 0)
        end
        for _, g in ipairs(info.guilds or {}) do total = total + (g.bank or 0) end
        GB.db.holdings[e.itemID] = total
      end
    end
  end
end

-- What you hold of an item and what it cost you: your buys, oldest sold first (first in, first out).
function L.CostBasis(itemID)
  local lots = {}
  for _, e in ipairs(GB.db.ledger) do
    if e.itemID == itemID then
      if e.kind == "buy" and (e.qty or 0) > 0 then
        lots[#lots + 1] = { qty = e.qty, unit = (e.price or 0) / e.qty }
      elseif e.kind == "sell" then
        local left = e.qty or 0
        while left > 0 and #lots > 0 do
          local take = math.min(left, lots[1].qty)
          lots[1].qty = lots[1].qty - take
          left = left - take
          if lots[1].qty <= 0 then table.remove(lots, 1) end
        end
      end
    end
  end
  local qty, cost = 0, 0
  for _, l in ipairs(lots) do qty, cost = qty + l.qty, cost + l.qty * l.unit end
  if qty == 0 then return nil end
  local held = GB.db.holdings[itemID]
  return { bought = qty, held = held and math.min(held, qty) or qty, avg = cost / qty }
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

function L.Init()
  if PlaceAuctionBid then hooksecurefunc("PlaceAuctionBid", OnBid) end
  if CancelAuction then hooksecurefunc("CancelAuction", OnCancel) end
  if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", function(i) OnMailTake(i, "money") end) end
  if TakeInboxItem then hooksecurefunc("TakeInboxItem", function(i) OnMailTake(i, "item") end) end
  if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", function(i) OnMailTake(i, "all") end) end

  local f = CreateFrame("Frame")
  f:RegisterEvent("CHAT_MSG_SYSTEM")
  f:RegisterEvent("AUCTION_HOUSE_CLOSED")
  f:SetScript("OnEvent", function(_, event, msg)
    if event == "CHAT_MSG_SYSTEM" then OnSystemMessage(GB.Clean(msg))
    elseif event == "AUCTION_HOUSE_CLOSED" then L.RefreshHoldings() end
  end)

  -- Auctionator's post report (its legacy auction house code); without Auctionator posts just aren't listed
  local bus = Auctionator and Auctionator.EventBus
  local events = Auctionator and Auctionator.Selling and Auctionator.Selling.Events
  if bus and events and events.PostSuccessful then
    pcall(bus.Register, bus, { ReceiveEvent = function(_, eventName, details)
      if eventName == events.PostSuccessful then OnPostSuccessful(details) end
    end }, { events.PostSuccessful })
  end
end
