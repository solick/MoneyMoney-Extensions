--
-- MoneyMoney Web Banking Extension for Bigbank AS (Germany)
-- https://www.bigbank.de
--
-- Fetches Tagesgeld (savings) and Festgeld (fixed-term deposit) accounts
-- with balances and transactions from the Bigbank self-service portal.
--
-- Authentication: Customer ID + Password, then mTAN (SMS OTP)
--
-- Copyright (c) 2026 Lyn Matten
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--

WebBanking {
  version     = 1.00,
  country     = "de",
  url         = "https://banking.bigbank.de",
  services    = {"Bigbank"},
  description = string.format(MM.localizeText("Get balance and transactions for %s"), "Bigbank")
}

-- API base URLs
local authBaseUrl    = "https://auth.bigbank.eu"
local bankingBaseUrl = "https://banking.bigbank.de"

-- State
local connection

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function jsonRequest(method, url, body)
  local headers = {
    ["Accept"]       = "application/json",
    ["Content-Type"] = "application/json"
  }
  local content = connection:request(method, url, body, "application/json", headers)
  return JSON(content):dictionary()
end

local function jsonGet(url)
  local headers = {
    ["Accept"] = "application/json"
  }
  local content = connection:request("GET", url, nil, nil, headers)
  return JSON(content):dictionary()
end

local function jsonPost(url, body)
  return jsonRequest("POST", url, body)
end

local function parseDate(dateStr)
  -- Parses ISO 8601 date strings like "2025-03-15" or "2025-03-15T10:30:00"
  if not dateStr then return nil end
  local y, m, d = string.match(dateStr, "(%d+)-(%d+)-(%d+)")
  if y then
    return os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0})
  end
  return nil
end

local function parseTimestamp(ts)
  -- Parses Unix timestamp in milliseconds
  if not ts then return nil end
  if type(ts) == "number" then
    if ts > 1e12 then
      return math.floor(ts / 1000)
    end
    return ts
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Bank support
-- ---------------------------------------------------------------------------

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Bigbank"
end

-- ---------------------------------------------------------------------------
-- Authentication (2FA: Customer ID + Password, then SMS mTAN)
-- ---------------------------------------------------------------------------

local function exchangeAuthCode(authCode)
  -- The OAuth flow requires going through auth.bigbank.eu/redirect which:
  -- 1. Uses the auth session cookie to look up the original redirect_uri and state
  -- 2. Redirects (302) to banking.bigbank.de/?code=XXX&state=YYY
  -- 3. The banking portal then exchanges the code for a self-session cookie
  -- Going directly to banking.bigbank.de/?code=... skips step 1 and fails.
  local redirectUrl = authBaseUrl .. "/redirect?code=" .. authCode .. "&method=customerid"
  MM.printStatus("Exchanging authorization code...")
  connection:get(redirectUrl)

  -- Verify we have a valid session by calling verifyUser
  local verifyContent = connection:request("POST", bankingBaseUrl .. "/gw/verifyUser", "{}", "application/json",
    {["Accept"] = "application/json"})
  local verifyResult = JSON(verifyContent):dictionary()

  if verifyResult and verifyResult["isLoggedIn"] then
    return true
  end

  return false
end

function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  if step == 1 then
    -- Step 1: Login with Customer ID and Password
    local username = credentials[1]
    local password = credentials[2]

    connection = Connection()
    connection.language = "de-de"

    -- First, hit the banking portal to initiate the OAuth flow.
    -- This redirects to auth.bigbank.eu which sets the authv2 session cookie
    -- and stores the redirect_uri + state server-side.
    connection:get(bankingBaseUrl .. "/")

    -- Now perform the credential login against the auth API
    -- (the authv2 cookie is sent automatically by Connection)
    local loginBody = JSON():set({
      username = username,
      password = password
    }):json()

    local loginResult = jsonPost(authBaseUrl .. "/api/auth/customer-id/login", loginBody)

    if loginResult and loginResult["status"] == "MFA_REQUIRED" then
      -- Server will send an SMS mTAN to the registered phone number
      local recipient = loginResult["recipient"] or ""
      return {
        title = "mTAN Eingabe",
        challenge = "Bitte geben Sie den mTAN-Code ein, der an " .. recipient .. " gesendet wurde.",
        label = "mTAN-Code"
      }
    elseif loginResult and loginResult["status"] == "LOGIN_SUCCESSFUL" then
      -- No 2FA required (unlikely but handle it)
      local authCode = loginResult["authorizationCode"]
      if authCode then
        if not exchangeAuthCode(authCode) then
          return "Session could not be established."
        end
      end
      return nil
    else
      return LoginFailed
    end

  elseif step == 2 then
    -- Step 2: Submit the mTAN OTP code
    local otpCode = credentials[1]

    local otpBody = JSON():set({
      otp = otpCode
    }):json()

    local otpResult = jsonPost(authBaseUrl .. "/api/auth/customer-id/submit/otp", otpBody)

    if otpResult and otpResult["status"] == "LOGIN_SUCCESSFUL" then
      local authCode = otpResult["authorizationCode"]
      if authCode then
        -- Exchange code through auth.bigbank.eu/redirect (proper OAuth flow)
        if not exchangeAuthCode(authCode) then
          return "Session could not be established."
        end
      end
      return nil
    else
      return LoginFailed
    end
  end
end

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

-- Store owner name from verifyUser for use in ListAccounts
local ownerName = ""

local function fetchOwnerName()
  local verifyContent = connection:request("POST", bankingBaseUrl .. "/gw/verifyUser", "{}", "application/json",
    {["Accept"] = "application/json"})
  local verifyResult = JSON(verifyContent):dictionary()
  if verifyResult and verifyResult["username"] then
    ownerName = verifyResult["username"]
  end
end

function ListAccounts(knownAccounts)
  local accounts = {}

  -- Get owner name if not already fetched
  if ownerName == "" then
    fetchOwnerName()
  end

  -- Fetch accounts from account service
  -- Response: [{"id":1036000,"iban":"EE43...","availableBalance":18441.69,"currencyCode":"EUR",
  --            "agreementTypeCode":"DC","accountTypeCode":"SAVEDE01"}]
  local bankAccounts = jsonGet(bankingBaseUrl .. "/account/api/accounts")

  if bankAccounts and type(bankAccounts) == "table" then
    for _, acc in ipairs(bankAccounts) do
      local accountType = AccountTypeSavings
      local typeCode = acc["accountTypeCode"] or ""
      local agreementCode = acc["agreementTypeCode"] or ""

      -- Detect account type from codes
      if agreementCode == "TD" or string.find(typeCode, "TERM") or string.find(typeCode, "FD") then
        accountType = AccountTypeFixedTermDeposit
      end

      local name = "Bigbank Tagesgeld"
      if accountType == AccountTypeFixedTermDeposit then
        name = "Bigbank Festgeld"
      end

      local account = {
        name          = name,
        owner         = ownerName,
        accountNumber = acc["iban"] or tostring(acc["id"] or ""),
        subAccount    = acc["id"] and tostring(acc["id"]) or nil,
        bankCode      = "Bigbank",
        currency      = acc["currencyCode"] or "EUR",
        iban          = acc["iban"] or "",
        bic           = "",
        type          = accountType
      }
      table.insert(accounts, account)
    end
  end

  return accounts
end

-- ---------------------------------------------------------------------------
-- Refresh: Balance + Transactions
-- ---------------------------------------------------------------------------

function RefreshAccount(account, since)
  local transactions = {}
  local balance = nil
  local accountId = account.subAccount

  MM.printStatus("Getting transactions since " .. os.date("%d.%m.%Y", since) .. "...")

  -- 1. Get balance from /account/api/accounts (most reliable source)
  -- Response: [{"id":1036000,"iban":"EE43...","availableBalance":18441.69,...}]
  local bankAccounts = jsonGet(bankingBaseUrl .. "/account/api/accounts")
  if bankAccounts and type(bankAccounts) == "table" then
    for _, acc in ipairs(bankAccounts) do
      if tostring(acc["id"]) == accountId or acc["iban"] == account.iban then
        balance = tonumber(acc["availableBalance"])
        break
      end
    end
  end

  -- 2. Fallback: get balance from deposit summary
  -- Response: [{"id":309141,"amount":18441.69,"interest":2.2,"accruedInterest":51.84,...}]
  if not balance then
    local summary = jsonGet(bankingBaseUrl .. "/deposit/api/dashboard/deposit-summary")
    if summary and type(summary) == "table" then
      for _, dep in ipairs(summary) do
        balance = tonumber(dep["amount"])
        break
      end
    end
  end

  -- 3. Fetch transactions via account-statement (GET with query params)
  -- Bigbank Germany has disableSavingDepositTransactions=true, so the deposit
  -- transaction endpoint returns []. The account-statement endpoint is the correct one.
  -- Override MoneyMoney's default period to fetch up to 3 years of history
  local threeYearsAgo = os.time() - (3 * 365 * 24 * 60 * 60)
  if since > threeYearsAgo then
    since = threeYearsAgo
  end
  local sinceDate = os.date("%Y-%m-%d", since)
  local todayDate = os.date("%Y-%m-%d")
  local pageSize = 100
  local pageNumber = 1
  local hasMore = true

  while hasMore do
    local stmtUrl = bankingBaseUrl .. "/account/api/account-statement"
      .. "?accountId=" .. MM.urlencode(accountId)
      .. "&startDate=" .. MM.urlencode(sinceDate)
      .. "&endDate=" .. MM.urlencode(todayDate)
      .. "&pageSize=" .. pageSize
      .. "&pageNumber=" .. pageNumber

    local stmtResult = jsonGet(stmtUrl)

    if stmtResult and stmtResult["transactions"] and type(stmtResult["transactions"]) == "table" then
      local txList = stmtResult["transactions"]

      for _, tx in ipairs(txList) do
        local bookingDate = parseDate(tx["bookingDate"] or tx["date"] or tx["transactionDate"])
          or parseTimestamp(tx["bookingTimestamp"] or tx["timestamp"])
        local valueDate = parseDate(tx["valueDate"]) or bookingDate

        local amount = tonumber(tx["amount"]) or tonumber(tx["sum"]) or 0
        local purpose = tx["description"] or tx["purpose"] or tx["type"] or tx["transactionType"] or ""
        local name = tx["counterpartyName"] or tx["name"] or tx["senderName"] or tx["recipientName"] or ""

        local transaction = {
          bookingDate = bookingDate,
          valueDate   = valueDate,
          name        = name,
          purpose     = purpose,
          amount      = amount,
          currency    = tx["currencyCode"] or tx["currency"] or account.currency or "EUR",
          booked      = tx["booked"] ~= false
        }
        table.insert(transactions, transaction)
      end

      -- Check if there are more pages
      local pagination = stmtResult["pagination"] or stmtResult["page"] or {}
      local totalPages = tonumber(pagination["totalPages"]) or 0

      if #txList < pageSize or pageNumber >= totalPages then
        hasMore = false
      else
        pageNumber = pageNumber + 1
      end
    else
      hasMore = false
    end
  end

  return {balance = balance, transactions = transactions}
end

-- ---------------------------------------------------------------------------
-- Logout
-- ---------------------------------------------------------------------------

function EndSession()
  if connection then
    connection:get(bankingBaseUrl .. "/gw/logout")
  end
end
