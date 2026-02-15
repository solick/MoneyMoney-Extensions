# MoneyMoney Bigbank Extension

A [MoneyMoney](https://moneymoney-app.com/) web banking extension for [Bigbank AS](https://www.bigbank.de/) (Germany).

Fetches account balances and transactions for Bigbank Tagesgeld (savings) and Festgeld (fixed-term deposit) accounts.

## Features

- Two-factor authentication via mTAN (SMS)
- Tagesgeld (daily savings) account balance and transactions
- Festgeld (fixed-term deposit) account balance
- Up to 3 years of transaction history

## Requirements

- [MoneyMoney](https://moneymoney-app.com/) (macOS)
- A Bigbank Germany customer account with Customer ID and password

## Installation

1. Download `Bigbank.lua`
2. Open Finder and navigate to:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```
   (You can also press `Cmd+Shift+G` in Finder and paste the path)
3. Copy `Bigbank.lua` into the `Extensions` folder
4. MoneyMoney picks up new extensions immediately — no restart needed

## Setup

1. In MoneyMoney, go to **Konto** > **Konto hinzufügen**
2. Select the **Sonstiges** tab (not the bank search)
3. Find and select **Bigbank** in the list
4. Enter your Bigbank **Kunden-ID** (Customer ID) as username
5. Enter your **password**
6. Click **Weiter** — an mTAN code will be sent to your registered phone via SMS
7. Enter the mTAN code and confirm

Your Bigbank accounts will be imported automatically.

## Notes

- **mTAN is always required** when logging in from MoneyMoney, even if your browser doesn't ask for it. This is because Bigbank treats MoneyMoney as a new/unknown device.
- **SMS delivery** may be delayed if you attempt to log in multiple times in a short period. Wait at least 10 minutes between retries if the SMS doesn't arrive.
- **Transaction history** is fetched for up to 3 years (Bigbank Germany supports up to 5 years).
- Only Bigbank Germany (`banking.bigbank.de`) is currently supported. Other Bigbank countries (Estonia, Finland, etc.) use different API configurations.

## How It Works

The extension communicates with Bigbank's REST API through the following flow:

1. **Authentication**: OAuth 2.0 Authorization Code flow via `auth.bigbank.eu` with Customer ID + Password + mTAN
2. **Accounts**: Fetched from `/account/api/accounts`
3. **Balances**: Primary source from account data, fallback from `/deposit/api/dashboard/deposit-summary`
4. **Transactions**: Fetched via `/account/api/account-statement` with pagination support

## License

MIT License — see [LICENSE](LICENSE) for details.
