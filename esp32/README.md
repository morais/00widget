# 00Widget for ESP32

A desk display for your 00Widget cards. It polls the API, shows one card per
screen, and lets a physical button run a card's action. Distributed as source:
you choose the cards, add your Wi-Fi and token, and flash it yourself.

Supported out of the box: **LilyGO T-Display S3** (ESP32-S3, 170×320 ST7789,
two buttons). Every board-specific detail lives in `src/board.h`, so porting to
another board means adding a display block there and an env in
`platformio.ini`.

## Setup

```sh
brew install platformio            # or: pip install platformio
cd esp32
cp include/config.h.sample include/config.h
$EDITOR include/config.h           # Wi-Fi, token, card ids
pio run -t upload                  # builds and flashes over USB
pio device monitor                 # optional: logs
```

`include/config.h` is gitignored, because it holds your token and Wi-Fi password.

### Choosing cards

`ZW_CARD_IDS` is the list of card ids to show, in order. Leave it as `{}` to
show every card on your dashboard in the server's order (highest `priority`
first). Card ids you list that don't exist show a "Not found" screen, so a typo
is visible instead of the card just being missing. To list the ids:

```sh
curl -s -H "Authorization: Bearer $TOKEN" https://api.00widget.com/v1/cards | jq -r '.cards[].id'
```

### The token

Any credential with the `read` scope works. The agent token from the app
(Settings → Agent token) has `read` and is the simplest choice. With that
token the device is **read-only**, and cards that have buttons say so in their
footer.

Running actions needs a token that also has `actions:run`. The device checks
`GET /v1/status` at startup and enables the action button when it finds the
scope. Actions marked `confirm: true` or `role: destructive` never run from
the device, which is the same rule widgets follow. Those cards say "Actions in
app".

## Buttons

| Button             | Press                 | Hold                         |
| ------------------ | --------------------- | ---------------------------- |
| **BOOT** (GPIO 0)  | Next card             | Refresh now                  |
| **KEY** (GPIO 14)  | Choose between a card's actions | Run the chosen action |

Running an action takes a hold, so brushing the button can't trigger one.
Cards also advance on their own every `ZW_AUTO_ROTATE_SECONDS`. Auto-advance
waits a minute after any button press. Define `ZW_SWAP_BUTTONS` to swap the
two buttons.

### Quiet period

Set `ZW_QUIET_START` and `ZW_QUIET_END` (local `"HH:MM"`, and the window may
span midnight) to turn the screen off overnight. Polling stops during that
time too. Pressing either button turns the screen on for
`ZW_QUIET_WAKE_SECONDS` (default 30), and each further press restarts that
window. The press that wakes the screen does nothing else, because in the
dark you can't see which card a press would act on. On waking, the device
fetches fresh cards straight away. If the clock hasn't synced yet, the
quiet period doesn't apply.

### Local control

Set `ZW_LOCAL_TOKEN` to let another device on your network put the screen to
sleep and wake it, for example a presence sensor or Home Assistant. The
device serves plain HTTP on port 80 and also answers as `00widget.local`
(`ZW_HOSTNAME`):

```sh
curl -X POST -H "Authorization: Bearer $LOCAL_TOKEN" http://00widget.local/sleep
curl -X POST "http://00widget.local/wake?token=$LOCAL_TOKEN"
```

| Request | Effect |
| --- | --- |
| `POST /sleep` | Screen off and polling stops. A button still wakes it for `ZW_QUIET_WAKE_SECONDS` |
| `POST /wake` | Screen on, even during the quiet period |
| `POST /auto` | Back to the quiet-period schedule |
| `GET /state` | `{"screen":"on","mode":"auto","quietPeriod":false}` |

A command lasts until the next command or a reboot, and a reboot returns the
device to `auto`. Each reply describes the state the command produces. The
token travels unencrypted, so use a long random one that isn't used anywhere
else (`openssl rand -hex 16`). On macOS, `curl` waits a few seconds on a
`.local` name while it tries IPv6, so pass `-4` or use the IP address that
the serial log prints at boot.

## What it draws

| Template | On the device |
| --- | --- |
| `summary`, `action`, `timeline` | Headline value and unit, subtitle, comparison, deadline countdown |
| `progress` | The above plus a bar |
| `list` | Headline, then as many rows as fit, with ranked bars when rows carry `amount` |
| `chart` | Headline and the plot: line, bar or delta, with the reference rule. Multi-series charts draw stacked or grouped bars with a legend, coloured by the same rules as iOS |
| `history` | Headline and one pip per outcome |
| `breakdown` | Headline, segmented bar, legend |
| `briefing` | Headline, subtitle, and the briefing text wrapped to fit |

The headline shrinks to fit the width. The footer shows when the card was last
updated. It shows **Stale** once `staleAfter` has passed and **Offline** when
the device itself can't reach the server, in which case the cards on screen
are the last ones it fetched.

## Network behaviour

- One `GET /v1/cards` every `ZW_POLL_SECONDS` (default 60), on a fresh TLS
  connection. The server's whole response is filtered while it streams, so
  memory doesn't grow with the size of the dashboard.
- TLS is verified against the roots in `src/roots.h`: Google Trust Services
  and Let's Encrypt, which cover Cloudflare. A self-hosted backend on another
  CA needs its root added there.
- The clock comes from NTP; set `ZW_TIMEZONE` to a POSIX TZ string.

## Screenshots over USB

The firmware answers a few single-character commands on its serial port:
`n`/`p` move between cards, `a`/`A` choose and run an action, `r` refreshes,
and `s` dumps the frame buffer. `tools/screenshot.py` uses them to save a PNG
of what the screen shows, which is how layout changes can be checked without
photographing the device:

```sh
python3 tools/screenshot.py /dev/cu.usbmodem* shot.png nn   # two cards on
```

It needs `pyserial`, which comes with PlatformIO.
