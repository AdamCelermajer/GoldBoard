-- The ledger: every auction house buy, sale, post, cancel and expiry, with what it cost or earned.
--
-- Sources, so nothing is guessed:
--   buys   : the buyout you place (C_AuctionHouse.PlaceBid for items, ConfirmCommoditiesPurchase for
--            commodities, whoever's UI calls them), confirmed by the game's purchase event or its "You won
--            an auction" message; a win you weren't online for is taken from its mail.
--   sales  : the "Auction successful" mail when you take its money (sale price, auction cut, deposit back).
--   expired / cancelled : their mails when you take the item back.
--   posts  : C_AuctionHouse.PostItem / PostCommodity (whoever calls them), written down once the game
--            says the auction was created. Cancels: C_AuctionHouse.CancelAuction.
-- This client has the modern auction house (C_AuctionHouse); the old PlaceAuctionBid family isn't there.
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
  if GB.Main and GB.Main.Refresh then GB.Main.Refresh() end
  return entry
end
L.Add = Add

-- "Auction won: %s" -> "^Auction won: (.+)$", from the game's own (localized) strings
local function Pattern(fmt)
  if type(fmt) ~= "string" then return nil end
  -- mark the one "%s" (or "%1$s"), escape every pattern character, then turn the mark into a capture
  local p, n = fmt:gsub("%%%d?%$?s", "\1", 1)
  if n == 0 then return nil end
  p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1"):gsub("\1", "(.+)")
  return "^" .. p .. "$"
end
L.Pattern = Pattern

-- "Linen Cloth (20)" -> "Linen Cloth", 20
local function SplitCount(name)
  local base, n = name:match("^(.-) %((%d+)%)$")
  if base then return base, tonumber(n) end
  return name, nil
end

---------------------------------------------------------------------------
-- Buys
---------------------------------------------------------------------------

local pending = {}   -- bids placed this session, waiting for the game to say they were won

local function ItemName(itemID, link)
  local name = link and link:match("%[(.-)%]")
  if not name and itemID and C_Item and C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(itemID) end
  return name
end

-- C_AuctionHouse.PlaceBid(auctionID, amount): an item auction bid on or bought out.
-- The game's answer can come during the call, before this hook runs: Gold Board's own Buy click says what it
-- bids just before the call (ExpectBid), and an answer for a bid nobody expected is kept a moment (early).
local bidDone, earlyBid, earlyWon = {}, {}, nil   -- [auctionID] = GetTime() of the answer; earlyWon = { name, at }
local function NewBid(auctionID, bid, expected)
  local info = C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
  if type(info) ~= "table" then return nil end   -- already sold
  local itemID = info.itemKey and info.itemKey.itemID
  -- one bid buys one item (a row's quantity is how many identical ones are up)
  local buyout = info.buyoutAmount
  local p = { t = time(), at = GetTime(), auctionID = auctionID, name = ItemName(itemID, info.itemLink) or ("item " .. tostring(itemID)),
              itemID = itemID, qty = 1, price = bid, buyout = buyout ~= nil and buyout > 0 and bid >= buyout, expected = expected }
  pending[#pending + 1] = p
  return p
end
function L.ExpectBid(auctionID, bid) if auctionID and bid then NewBid(auctionID, bid, true) end end
local function OnBid(auctionID, bid)
  auctionID, bid = GB.Clean(auctionID), GB.Clean(bid)
  if not auctionID or not bid then return end
  local now = GetTime()
  if bidDone[auctionID] == now then return end                  -- answered during the call: already written
  for _, p in ipairs(pending) do if p.auctionID == auctionID and p.expected and p.at == now then return end end
  if earlyBid[auctionID] == now then
    -- somebody else's bid answered during its own call: written now, from what is still known
    earlyBid[auctionID] = nil
    local info = C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
    local itemID = type(info) == "table" and info.itemKey and info.itemKey.itemID or nil
    local name = (type(info) == "table" and ItemName(itemID, info.itemLink)) or (earlyWon and earlyWon.at == now and earlyWon.name) or nil
    itemID = itemID or (name and GB.IDFromName(name))
    bidDone[auctionID] = now
    Add({ kind = "buy", itemID = itemID, name = name or ("item " .. tostring(itemID)), qty = 1, price = bid, source = "won" })
    return
  end
  NewBid(auctionID, bid, false)
end
L.OnBid = OnBid

-- AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID): the buyout went through
local function OnPurchaseCompleted(auctionID)
  for i, p in ipairs(pending) do
    if p.auctionID == auctionID then
      table.remove(pending, i)
      bidDone[auctionID] = GetTime()
      Add({ kind = "buy", t = p.t, itemID = p.itemID, name = p.name, qty = p.qty, price = p.price, source = "won" })
      return
    end
  end
  if auctionID and auctionID ~= 0 then earlyBid[auctionID] = GetTime() end
end

-- Commodities are bought by quantity: the game quotes a total (COMMODITY_PRICE_UPDATED), you confirm it
-- (ConfirmCommoditiesPurchase) and it answers COMMODITY_PURCHASE_SUCCEEDED or _FAILED. That answer can also
-- come during the confirm call: the Buy click says what it confirms just before (ExpectCommodityConfirm).
local quote, commodity, commodityDone, earlyCommodity = nil, nil, nil, nil
local function OnCommodityQuote(unit, total) quote = { unit = GB.Clean(unit), total = GB.Clean(total), t = time() } end
local function OnCommodityDone(ok)
  local c = commodity
  commodity = nil
  if not c then
    if ok then earlyCommodity = GetTime() end    -- an answer before anything waited for it (kept a moment)
    return
  end
  commodityDone = { itemID = c.itemID, qty = c.qty, at = GetTime() }
  if ok and time() - c.t < 30 then
    Add({ kind = "buy", t = c.t, itemID = c.itemID, name = ItemName(c.itemID) or ("item " .. c.itemID), qty = c.qty,
          price = c.price, source = "won", commodity = true })
  end
end
local function NewConfirm(itemID, qty, expected)
  if not (itemID and qty and quote and quote.total and time() - quote.t < 120) then commodity = nil return end
  commodity = { t = time(), at = GetTime(), itemID = itemID, qty = qty, price = quote.total, expected = expected }
end
function L.ExpectCommodityConfirm(itemID, qty) NewConfirm(itemID, qty, true) end
local function OnCommodityConfirm(itemID, qty)
  local now = GetTime()
  if commodity and commodity.expected and commodity.at == now and commodity.itemID == itemID and commodity.qty == qty then return end
  if commodityDone and commodityDone.at == now and commodityDone.itemID == itemID and commodityDone.qty == qty then return end
  NewConfirm(itemID, qty, false)
  if earlyCommodity == now then earlyCommodity = nil; OnCommodityDone(true) end   -- it already went through
end

local BUYOUT_WAIT = 60   -- a buyout is won at once: one still waiting after this long failed (no gold, already sold)

local wonPattern
local function OnSystemMessage(msg)
  wonPattern = wonPattern or Pattern(ERR_AUCTION_WON_S)
  local name = wonPattern and msg and msg:match(wonPattern)
  if not name then return end
  earlyWon = { name = SplitCount(name), at = GetTime() }   -- for a win announced during its own call
  local base = SplitCount(name)   -- in case the message carries the stack size
  local now = time()
  for i = #pending, 1, -1 do
    if pending[i].buyout and now - pending[i].t > BUYOUT_WAIT then table.remove(pending, i) end
  end
  -- a buyout you just clicked comes before an older bid that is still running on the same item
  local found
  for i, p in ipairs(pending) do
    if (p.name == name or p.name == base) and p.buyout then found = i break end
  end
  if not found then
    for i, p in ipairs(pending) do
      if p.name == name or p.name == base then found = i break end
    end
  end
  if not found then return end
  local p = table.remove(pending, found)
  bidDone[p.auctionID] = GetTime()
  Add({ kind = "buy", t = p.t, itemID = p.itemID, name = p.name, qty = p.qty, price = p.price, source = "won" })
end
L.OnSystemMessage = OnSystemMessage

-- A won-auction mail: already in the ledger (you were online when you won it) or a new buy.
-- link and attached (the item and how many) were read from the mail when you took it.
local function RecordWonMail(name, count, bid, sentAt, link, attached)
  local base, n = SplitCount(name)
  local qty = count or n
  if not qty then qty = attached and attached > 0 and attached or nil end
  name, qty = base, qty or 1
  for i = #GB.db.ledger, math.max(1, #GB.db.ledger - 300), -1 do
    local e = GB.db.ledger[i]
    if e.kind == "buy" and not e.mailed and e.name == name and math.abs(e.t - sentAt) < 3 * 86400 then
      if e.commodity then
        -- a commodity bought in one go can arrive as several mails: they add up to the buy already recorded
        e.mailedQty = (e.mailedQty or 0) + qty
        if e.mailedQty >= (e.qty or 0) then e.mailed = true end
        return
      elseif e.price == bid then
        e.mailed = true
        return
      end
    end
  end
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

L.MailKind = MailKind

-- A take is written down only once the inbox shows the money or the item gone (a take can fail, for
-- example with full bags). Mails are told apart by what they hold and when they were sent, not by their
-- place in the inbox (which shifts as mails are deleted): a take is confirmed when one fewer mail like it
-- still holds that money or item. Several identical mails taken one after the other are each counted; one
-- mail clicked twice in a row, once.
-- The inbox shows at most 50 mails; when one goes, another from the server can move up. The send time in
-- the signature keeps such a mail from being taken for the one that went (unless sent within SAME_SENT).
local MAIL_WAIT = 60           -- a take not confirmed by then failed (or the mailbox closed): dropped
local SAME_SENT = 120          -- mails sent this close together (seconds) can't be told apart by their send time
local DOUBLE_CLICK = 0.5       -- a second take of the same mail this soon, with nothing changed, is the same take
local takes = {}               -- { sig, sent, base, at, index, count, apply }, oldest first

local function MailSig(index)
  local _, _, sender, subject, money, _, daysLeft, itemCount = GetInboxHeaderInfo(index)
  if not subject then return nil end
  local stack
  if GetInboxItem and (itemCount or 0) > 0 then stack = select(4, GetInboxItem(index, 1)) end
  local sent = time() - (MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400
  return table.concat({ tostring(sender), tostring(subject), tostring(money or 0), tostring(itemCount or 0), tostring(stack or 0) }, "|"), sent
end
local function CountLike(sig, sent)
  local n = 0
  for i = 1, (GetInboxNumItems() or 0) do
    local s, t = MailSig(i)
    if s == sig and math.abs(t - sent) < SAME_SENT then n = n + 1 end
  end
  return n
end
local function Same(p, sig, sent) return p.sig == sig and math.abs(p.sent - sent) < SAME_SENT end

local function CheckTakes()
  if #takes == 0 then return end
  local keep, now = {}, GetTime()
  for _, p in ipairs(takes) do p.group = nil end
  -- group the waiting takes of mails alike; each group's mails gone so far
  local groups = {}
  for _, p in ipairs(takes) do
    for _, g in ipairs(groups) do if Same(g.first, p.sig, p.sent) then p.group = g break end end
    if not p.group then
      p.group = { first = p, used = 0 }
      p.group.gone = math.max(0, p.base - CountLike(p.sig, p.sent))
      groups[#groups + 1] = p.group
    end
  end
  for _, p in ipairs(takes) do
    local g = p.group
    if g.used < g.gone then
      g.used = g.used + 1
      local ok, err = pcall(p.apply)
      if not ok then GB.Report(err, "ledger mail") end
    else
      p.base = p.base - g.gone
      if now - p.at < MAIL_WAIT then keep[#keep + 1] = p end
    end
    p.group = nil
  end
  takes = keep
end
L.CheckTakes = CheckTakes

-- what: "money" (TakeInboxMoney), "item" (TakeInboxItem) or "all" (AutoLootMailItem, open-all addons)
-- Everything is read from the inbox now, while the index still points at this mail.
local function OnMailTake(index, what)
  local _, _, sender, subject, money, _, daysLeft, itemCount = GetInboxHeaderInfo(index)
  local kind, subjectName = MailKind(subject)
  if not kind then return end
  local sentAt = time() - math.floor((MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400)
  -- invoiceType, itemName, playerName, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count
  local invoiceType, itemName, bid, buyout, deposit, consignment, count, _
  if GetInboxInvoiceInfo then
    invoiceType, itemName, _, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
  end
  if type(count) ~= "number" or count <= 0 then count = nil end   -- unknown: the "(20)" in the name says it
  local link = GetInboxItemLink and GetInboxItemLink(index, 1)
  local attachedID, attached
  if GetInboxItem then _, attachedID, _, attached = GetInboxItem(index, 1) end

  local apply
  if kind == "sell" and (what == "money" or what == "all") and (money or 0) > 0 then
    apply = function()
      local name, n = SplitCount(itemName or subjectName)
      if not n then _, n = SplitCount(subjectName) end
      Add({ kind = "sell", t = sentAt, name = name, qty = count or n or 1, price = bid or 0, cut = consignment or 0,
            deposit = deposit or 0, net = money or 0, buyout = buyout, source = "mail" })
    end
  elseif kind == "won" and (what == "item" or what == "all") and (itemCount or 0) > 0 then
    apply = function() RecordWonMail(itemName or subjectName, count, bid or 0, sentAt, link, attached) end
  elseif (kind == "expire" or kind == "cancel") and (what == "item" or what == "all") and (itemCount or 0) > 0 then
    apply = function()
      local name, subjectCount = SplitCount(subjectName)
      local n = (attached and attached > 0) and attached or subjectCount or 1
      -- a cancel already written down when the game confirmed it: its mail only confirms it
      if kind == "cancel" then
        for i = #GB.db.ledger, math.max(1, #GB.db.ledger - 300), -1 do
          local e = GB.db.ledger[i]
          if e.kind == "cancel" and not e.mailed and e.name == name and (e.qty or 1) == n and math.abs(e.t - sentAt) < 3 * 86400 then
            e.mailed = true
            return
          end
        end
      end
      Add({ kind = kind, t = sentAt, itemID = GB.ItemIDFromLink(link) or attachedID, name = name, qty = n, source = "mail",
            mailed = true })
    end
  end
  if not apply then return end
  -- a client without the inbox count can't confirm anything: written at once, as before
  if not GetInboxNumItems then apply() return end
  local sig, sent = MailSig(index)
  local now, count = GetTime(), CountLike(sig, sent)
  -- the same mail clicked again a moment later, with the inbox unchanged: one take
  for _, p in ipairs(takes) do
    if p.index == index and Same(p, sig, sent) and now - p.at < DOUBLE_CLICK and p.count == count then return end
  end
  -- mails alike still waiting share one count (how many of them the inbox held before any was taken)
  local base = count
  for _, p in ipairs(takes) do if Same(p, sig, sent) and p.base > base then base = p.base end end
  for _, p in ipairs(takes) do if Same(p, sig, sent) then p.base = base end end
  takes[#takes + 1] = { sig = sig, sent = sent, index = index, count = count, base = base, at = now, apply = apply }
end

L.OnMailTake = OnMailTake

---------------------------------------------------------------------------
-- Posts and cancels
---------------------------------------------------------------------------

-- what an item location (a bag slot) holds
local function LocationItem(location)
  local itemID, link
  if C_Item and C_Item.GetItemID then
    local ok, id = pcall(C_Item.GetItemID, location)
    if ok then itemID = id end
  end
  if C_Item and C_Item.GetItemLink then
    local ok, l = pcall(C_Item.GetItemLink, location)
    if ok then link = l end
  end
  return itemID, ItemName(itemID, link)
end

-- PostItem(location, duration, quantity, bid, buyout) / PostCommodity(location, duration, quantity, unitPrice):
-- remembered, and written down once the game shows it went up.
local posting = nil
-- The game's "are you sure?" can come during the post call itself, before the hook below runs: its
-- moment is kept so the post made in that same call is known to wait for the popup.
local warnAt = nil
-- The other answers can come during the call too: Gold Board's own Post click says what it posts just
-- before the call (ExpectPost); for a post made elsewhere, the answers seen with nothing waiting are kept
-- for that moment (early) and handed to the post when its hook runs.
local early, recorded = {}, nil       -- early = { { at, event, a1, a2 } }; recorded = { itemID, at } of the last post written
local Replay
local function NewPost(location, duration, quantity, unit, isCommodity, expected)
  local itemID, name = LocationItem(location)
  if not itemID then return end
  local now = GetTime()
  if not expected then
    if posting and posting.expected and posting.at == now and posting.itemID == itemID then return end   -- this very call, already waited for
    if recorded and recorded.at == now and recorded.itemID == itemID then return end                    -- and already written during it
  end
  posting = { t = time(), at = now, itemID = itemID, name = name, qty = quantity or 1, unit = unit, duration = duration,
              before = GB.BagCount(itemID), commodity = isCommodity, expected = expected }
  if warnAt and now - warnAt < 1 then posting.confirm = true end
  warnAt = nil
  if not expected then Replay(now) end
end
local function OnPostItem(location, duration, quantity, bid, buyout) NewPost(location, duration, quantity, buyout or bid, false) end
local function OnPostCommodity(location, duration, quantity, unitPrice) NewPost(location, duration, quantity, unitPrice, true) end
function L.ExpectPost(location, duration, quantity, unit, isCommodity) NewPost(location, duration, quantity, unit, isCommodity, true) end
-- A post is written down once, by whichever proof comes first: the game's "auction created" event, its
-- multi-sell progress, or the items having left your bags (this client doesn't always send the event).
-- Several items posted in one click (a multi-sell) are written down when all of them are up, or when it
-- stops; without one, only when all of them left the bags, or a moment after the last one did.
-- A post waiting on the game's confirm popup is kept longer.
local POST_PROOF, POST_CONFIRM, SETTLE = 20, 90, 2
local function RecordPost(qty)
  local p = posting
  posting = nil
  if not p or qty <= 0 then return end
  recorded = { itemID = p.itemID, at = GetTime() }
  Add({ kind = "post", itemID = p.itemID, name = p.name, qty = qty, unit = p.unit, price = p.unit and p.unit * qty or nil,
        duration = p.duration, source = "ah" })
end
local function Live(p)
  return p and time() - p.t <= (p.confirm and POST_CONFIRM or POST_PROOF)
end
local function LeftBags(p)
  local now = GB.BagCount(p.itemID)
  return (p.before and now) and math.max(0, p.before - now) or 0
end
local function Early(event, a1, a2)
  local now = GetTime()
  if early[1] and early[1].at ~= now then early = {} end
  early[#early + 1] = { at = now, event = event, a1 = a1, a2 = a2 }
end
local function OnAuctionCreated()
  local p = posting
  if not Live(p) then Early("AUCTION_HOUSE_AUCTION_CREATED") return end
  if p.multisell then return end                      -- a multi-sell is counted by its own progress
  p.created = (p.created or 0) + 1
  if p.commodity or p.qty <= 1 or p.created >= p.qty then RecordPost(p.qty)
  else p.settleAt = GetTime() + SETTLE end           -- one auction of several: the rest may follow
end
local function OnBagsChanged()
  local p = posting
  if not Live(p) or p.multisell then return end
  local left = LeftBags(p)
  if left >= p.qty then RecordPost(p.qty)
  elseif left > 0 and left ~= p.left then p.left, p.settleAt = left, GetTime() + SETTLE end
end
local function OnMultisell(event, done, total)
  local p = posting
  if not Live(p) then Early(event, done, total) return end
  p.t = time()                                        -- in progress: a long multi-sell stays alive
  if event == "AUCTION_MULTISELL_START" then
    p.multisell, p.settleAt = { total = tonumber(done) or p.qty, done = 0 }, nil
  elseif event == "AUCTION_MULTISELL_UPDATE" then
    p.multisell = p.multisell or { total = tonumber(total) or p.qty, done = 0 }
    p.multisell.done, p.multisell.total = tonumber(done) or p.multisell.done, tonumber(total) or p.multisell.total
    if p.multisell.done >= p.multisell.total then RecordPost(math.min(p.qty, p.multisell.done)) end
  elseif event == "AUCTION_MULTISELL_FAILURE" then
    RecordPost(math.min(p.qty, math.max(p.multisell and p.multisell.done or 0, LeftBags(p))))
  end
end
-- the answers that came during the post call, before its hook: handed to it now
function Replay(now)
  local list = early
  early = {}
  for _, e in ipairs(list) do
    if e.at == now and posting then
      if e.event == "AUCTION_HOUSE_AUCTION_CREATED" then OnAuctionCreated() else OnMultisell(e.event, e.a1, e.a2) end
    end
  end
end
-- a moment after only part of a post left the bags, with no multi-sell running: what went up is written
local settle = CreateFrame("Frame")
settle:SetScript("OnUpdate", GB.Safe(function()
  local p = posting
  if not (p and p.settleAt) or GetTime() < p.settleAt or p.multisell then return end
  RecordPost(math.min(p.qty, math.max(p.created or 0, LeftBags(p))))
end, "ledger post"))
-- the Sell tab saw its post go up (it polls the bags itself): written down now unless it already was
function L.PostProven(itemID, qty)
  if posting and posting.itemID == itemID then RecordPost(math.min(posting.qty, qty or posting.qty)) end
end
local function OnPostWarning()
  warnAt = GetTime()
  if posting then posting.confirm = true end
end
-- you answered the game's "are you sure?" popup: the post is sent now, so its proof is awaited from now
-- (the Sell tab sees the answer through confirmedAt)
local function OnPostConfirmed()
  L.confirmedAt = GetTime()
  if posting then posting.t, posting.confirm, posting.before = time(), true, GB.BagCount(posting.itemID) end
end

-- C_AuctionHouse.CancelAuction(auctionID): which of your auctions that was, written down when the game
-- says it was cancelled (AUCTION_CANCELED), not when it was asked
local CANCEL_WAIT = 60
local cancels = {}     -- [auctionID] = { at, entry }
local early = {}       -- [auctionID] = when the game said it was cancelled, before anything was waiting for it
local OnCanceled
local function WaitCancel(auctionID)
  local A = C_AuctionHouse
  if cancels[auctionID] or not (A.GetNumOwnedAuctions and A.GetOwnedAuctionInfo) then return end
  for i = 1, A.GetNumOwnedAuctions() or 0 do
    local info = A.GetOwnedAuctionInfo(i)
    if info and info.auctionID == auctionID then
      local itemID = info.itemKey and info.itemKey.itemID
      local qty = info.quantity or 1
      cancels[auctionID] = { at = GetTime(), entry = { kind = "cancel", t = time(), itemID = itemID, name = ItemName(itemID, info.itemLink), qty = qty,
        price = info.buyoutAmount and info.buyoutAmount * qty or nil, source = "ah" } }
      return
    end
  end
end
-- the Cancel tab, just before its call (the auction is still in your list then, and the game's answer
-- can come during the call, before the hook below runs)
L.ExpectCancel = WaitCancel
local function OnCancel(auctionID)
  WaitCancel(auctionID)
  if early[auctionID] and GetTime() - early[auctionID] < 2 then early[auctionID] = nil; OnCanceled(auctionID) end
end
function OnCanceled(auctionID)
  local now, id = GetTime(), auctionID
  if id == nil then   -- an answer that names no auction: the oldest one waiting
    local oldest
    for k, c in pairs(cancels) do if not oldest or c.at < cancels[oldest].at then oldest = k end end
    id = oldest
  end
  local c = id ~= nil and cancels[id]
  if c then cancels[id] = nil; Add(c.entry)
  elseif auctionID ~= nil then early[auctionID] = now end
  for k, w in pairs(cancels) do if now - w.at > CANCEL_WAIT then cancels[k] = nil end end
  for k, t in pairs(early) do if now - t > 2 then early[k] = nil end end
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

-- The auction house functions live in C_AuctionHouse and the mail ones are globals. Whatever isn't there
-- yet when you log in is tried again when the auction house or the mailbox opens.
local hooks = {
  { "C_AuctionHouse", "PlaceBid", OnBid },
  { "C_AuctionHouse", "ConfirmCommoditiesPurchase", OnCommodityConfirm },
  { "C_AuctionHouse", "PostItem", OnPostItem },
  { "C_AuctionHouse", "PostCommodity", OnPostCommodity },
  { "C_AuctionHouse", "ConfirmPostItem", OnPostConfirmed },
  { "C_AuctionHouse", "ConfirmPostCommodity", OnPostConfirmed },
  { "C_AuctionHouse", "CancelAuction", OnCancel },
  { nil, "TakeInboxMoney", function(i) OnMailTake(i, "money") end },
  { nil, "TakeInboxItem", function(i) OnMailTake(i, "item") end },
  { nil, "AutoLootMailItem", function(i) OnMailTake(i, "all") end },
}
local hooked = {}
local function Hook()
  for _, h in ipairs(hooks) do
    local owner = h[1] and _G[h[1]] or _G
    if not hooked[h[2]] and (h[1] == nil or type(owner) == "table") and type(owner[h[2]]) == "function" then
      hooked[h[2]] = true
      if h[1] then hooksecurefunc(owner, h[2], GB.Safe(h[3], "ledger " .. h[2]))
      else hooksecurefunc(h[2], GB.Safe(h[3], "ledger " .. h[2])) end
    end
  end
end
L.Hooked = hooked

function L.Init()
  Hook()
  local f = CreateFrame("Frame")
  for _, e in ipairs({ "CHAT_MSG_SYSTEM", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_SHOW", "MAIL_SHOW", "AUCTION_HOUSE_PURCHASE_COMPLETED",
                       "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
                       "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING", "BAG_UPDATE_DELAYED", "BAG_UPDATE",
                       "AUCTION_MULTISELL_START", "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE", "AUCTION_CANCELED",
                       "MAIL_INBOX_UPDATE", "MAIL_CLOSED", "PLAYER_MONEY" }) do
    pcall(f.RegisterEvent, f, e)   -- an event this client doesn't know is skipped, not an error
  end
  f:SetScript("OnEvent", GB.Safe(function(_, event, a1, a2)
    if event == "CHAT_MSG_SYSTEM" then OnSystemMessage(GB.Clean(a1))
    elseif event == "AUCTION_HOUSE_CLOSED" then L.RefreshHoldings()
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then OnPurchaseCompleted(a1)
    elseif event == "COMMODITY_PRICE_UPDATED" then OnCommodityQuote(a1, a2)
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then OnCommodityDone(true)
    elseif event == "COMMODITY_PURCHASE_FAILED" then OnCommodityDone(false)
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then OnAuctionCreated()
    elseif event == "AUCTION_HOUSE_POST_WARNING" then OnPostWarning()
    elseif event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE" then OnBagsChanged(); CheckTakes()
    elseif event == "AUCTION_MULTISELL_START" or event == "AUCTION_MULTISELL_UPDATE" or event == "AUCTION_MULTISELL_FAILURE" then OnMultisell(event, a1, a2)
    elseif event == "AUCTION_CANCELED" then OnCanceled(a1)
    elseif event == "MAIL_INBOX_UPDATE" or event == "PLAYER_MONEY" then CheckTakes()
    elseif event == "MAIL_CLOSED" then CheckTakes(); takes = {}     -- looked at once more; one still unconfirmed is dropped
    else Hook() end
  end, "ledger"))
end
