#!/usr/bin/env bash
set -euo pipefail

CRED_FILE="/mnt/d/WriteHere/.credentials/aero-multiplier.env"
if [ -f "$CRED_FILE" ]; then
  set +a
  . "$CRED_FILE"
  set -a
fi

TELEGRAM_BOT_TOKEN="${AERO_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
TELEGRAM_CHAT_ID="${AERO_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
GOOGLE_SHEET_ID="${GOOGLE_SHEET_ID:-}"

DATE=$(TZ=UTC date +%Y-%m-%d\ %H:%M\ UTC)
DATA_DIR="/mnt/d/WriteHere/data"
HISTORY_FILE="$DATA_DIR/aero-multiplier-history.jsonl"

LIGHTPANDA_BIN="/home/pochu1215/.local/bin/lightpanda"
if [ ! -x "$LIGHTPANDA_BIN" ]; then
  echo "ERROR: Lightpanda not found at $LIGHTPANDA_BIN" >&2
  exit 1
fi
VOTE_HTML=$("$LIGHTPANDA_BIN" fetch --dump html --wait-until networkidle --wait-ms 20000 --http-timeout 20000 https://aerodrome.finance/vote 2>/dev/null || true)

NEW_EMISSIONS=$(echo "$VOTE_HTML" | grep -oP 'New Emissions:.*?<span[^>]*data-test-amount="\K[^"]+' | head -1)
NEW_EMISSIONS=$(echo "$NEW_EMISSIONS" | tr -d ',')
TOTAL_REWARDS=$(echo "$VOTE_HTML" | grep -oP 'Total Rewards.*?\$[0-9,]+(?:\.[0-9]+)?' | head -1 | sed -e 's/[^0-9.]//g')

if ! echo "$NEW_EMISSIONS" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  echo "ERROR: Failed to extract NEW_EMISSIONS (got: '$NEW_EMISSIONS')" >&2
  NEW_EMISSIONS=""
fi
if ! echo "$TOTAL_REWARDS" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  echo "ERROR: Failed to extract TOTAL_REWARDS (got: '$TOTAL_REWARDS')" >&2
  TOTAL_REWARDS=""
fi

AERO_PRICE=$(curl -s --fail --max-time 10 'https://api.coingecko.com/api/v3/simple/price?ids=aerodrome-finance&vs_currencies=usd' 2>/dev/null | grep -oP '"usd":\K[0-9.]+' || echo "")
if ! echo "$AERO_PRICE" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  echo "ERROR: Failed to fetch AERO price (got: '$AERO_PRICE')" >&2
  AERO_PRICE=""
fi

EMISSIONS_VALUE=""
MULTIPLIER=""
if [ -n "$NEW_EMISSIONS" ] && [ -n "$TOTAL_REWARDS" ] && [ -n "$AERO_PRICE" ]; then
  EMISSIONS_VALUE=$(python3 -c "print('{:.6f}'.format(float('$NEW_EMISSIONS') * float('$AERO_PRICE')))" 2>/dev/null || echo "")
  MULTIPLIER=$(python3 -c "print('{:.6f}'.format(float('$EMISSIONS_VALUE') / float('$TOTAL_REWARDS')))" 2>/dev/null || echo "")
  EMISSIONS_VALUE=$(echo "$EMISSIONS_VALUE" | sed -e 's/\.0*$//' -e 's/\(\.[0-9]*[1-9]\)0*$/\1/')
  MULTIPLIER=$(echo "$MULTIPLIER" | sed -e 's/\.0*$//' -e 's/\(\.[0-9]*[1-9]\)0*$/\1/')
fi

format_number() {
  python3 -c "n=float('$1'); print(f'{n:,.2f}' if n>=1 else f'{n:.4f}')" 2>/dev/null || echo "$1"
}
NE_FMT=$(format_number "$NEW_EMISSIONS")
TR_FMT=$(format_number "$TOTAL_REWARDS")
PRICE_FMT=$(format_number "$AERO_PRICE")
EV_FMT=$(format_number "$EMISSIONS_VALUE")
MULT_FMT=$(format_number "$MULTIPLIER")

REPORT="📊 Aerodrome Multiplier Report — $DATE

Current Stats:
• New Emissions: ${NE_FMT} AERO
• Total Rewards: \$${TR_FMT}
• AERO Price: \$${PRICE_FMT}
• Emissions Value: \$${EV_FMT}

🎯 Current Multiplier: ${MULT_FMT}x
(Emission value ÷ Total Rewards)

📈 Simulated Multipliers (added incentives):"
if [ -n "$EMISSIONS_VALUE" ] && [ -n "$TOTAL_REWARDS" ]; then
  for inc in 1000 25000 50000 100000; do
    sim=$(python3 -c "print('{:.2f}'.format(float('$EMISSIONS_VALUE') / (float('$TOTAL_REWARDS') + $inc)))" 2>/dev/null | sed -e 's/\.0*$//')
    REPORT="$REPORT"$'\n'" + $inc -> ${sim}x"
  done
else
  REPORT="$REPORT"$'\n'" N/A -> N/Ax"
fi
REPORT="$REPORT"$'\n'"Note: Adding incentives increases total rewards while emissions stay fixed, so multiplier decreases."$'\n'"$'\n'""🧮 Calculate your own: https://aero-multiplier-calculator.pages.dev/"

echo "$REPORT"
mkdir -p "$DATA_DIR"
echo "{\"date\":\"$DATE\",\"newEmissions\":\"$NEW_EMISSIONS\",\"totalRewards\":\"$TOTAL_REWARDS\",\"aeroPrice\":\"$AERO_PRICE\",\"emissionsValue\":\"$EMISSIONS_VALUE\",\"multiplier\":\"$MULTIPLIER\"}" >> "$HISTORY_FILE"

if [ -n "$GOOGLE_SHEET_ID" ] && [ -n "$AERO_TELEGRAM_BOT_TOKEN" ]; then
  PYTHON_BIN="/mnt/d/WriteHere/.venv/bin/python"
  if [ -x "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" - <<'PYEOF'
import os, gspread
from google.oauth2.credentials import Credentials

google_env = '/mnt/d/WriteHere/.credentials/google.env'
with open(google_env) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'): continue
        if '=' in line:
            k, v = line.split('=', 1)
            os.environ[k] = v

SCOPES = ['https://www.googleapis.com/auth/drive', 'https://www.googleapis.com/auth/spreadsheets']
creds = Credentials(
    token=None,
    refresh_token=os.getenv('GOOGLE_REFRESH_TOKEN'),
    token_uri='https://oauth2.googleapis.com/token',
    client_id=os.getenv('GOOGLE_CLIENT_ID'),
    client_secret=os.getenv('GOOGLE_CLIENT_SECRET'),
    scopes=SCOPES
)

try:
    gc = gspread.authorize(creds)
    sh = gc.open_by_key(os.getenv('GOOGLE_SHEET_ID'))
    ws = sh.sheet1
    row = [os.getenv('DATE')]
    for key in ['NEW_EMISSIONS','TOTAL_REWARDS','AERO_PRICE','EMISSIONS_VALUE','MULTIPLIER']:
        val = os.getenv(key)
        row.append(float(val) if val else None)
    try:
        ne = float(os.getenv('NEW_EMISSIONS'))
        tr = float(os.getenv('TOTAL_REWARDS'))
        ev = float(os.getenv('EMISSIONS_VALUE'))
        for inc in [1000, 25000, 50000, 100000]:
            sim = ev / (tr + inc)
            row.append(sim)
    except:
        while len(row) < 10: row.append(None)
    ws.append_row(row, value_input_option='RAW')
    print('Google Sheets: row appended')
except Exception as e:
    print(f'Google Sheets error: {e}')
PYEOF
  else
    echo "WARN: Python venv not found at $PYTHON_BIN; skipping Google Sheets" >&2
  fi
fi

if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  curl -s --fail "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$REPORT" \
    -d parse_mode="" >/dev/null || echo "WARN: Telegram send failed" >&2
else
  echo "INFO: Telegram not configured" >&2
fi

exit 0
