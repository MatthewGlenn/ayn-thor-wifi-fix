# AYN Thor — Wi-Fi won't connect to a WPA2/WPA3 mixed-mode network

**TL;DR:** The Thor fails to connect to WiFi networks sometimes and throws an authentication error. This is related to networks that present WPA2 and WPA3 at the same time (my router 😭). Pinning the BSSID fixes it. This script that does it automatically on every boot. **Root required.**

---

## Why it happens (slightly longer version that DeepSeek mostly wrote)

1. If your router broadcasts WPA2 and WPA3-SAE on the same SSID — most mesh
   systems do — Android creates a linked profile pair and the WPA3 half is
   malformed on this firmware. Network selection picks it, SAE never completes,
   and you get a 10-second timeout. Deleting the profile doesn't help; the
   framework regenerates it from scan results.
2. After enough failed attempts the router stops answering your auth frames
   entirely, on every band. The kernel log shows `Auth TX: success` followed by
   `AUTH failure timeout` — the frame went out and nothing came back.

Both need fixing: pin the BSSID with `-b` to force one clean profile, and use a
randomized MAC with `-r auto` so the router can't blacklist you. Pinning alone
works until the router blocks you; a randomized MAC alone still hits the
paired-profile bug. The manual fix is one command, but it doesn't survive a
reboot — the paired profile comes back and the framework re-picks the broken
WPA3 half. That's what the script automates.

## Confirm it's this bug before you go further

You need three things: proof the failure is an SAE timeout, the BSSID of the AP
you want to pin to, and the security type of that AP. All three come off the
device.

> **Running these from a computer?** The commands below are written for a root
> shell on the Thor itself. If you're on a computer, wrap each one in
> `adb shell "su -c '...'"` — for example
> `adb shell "su -c 'cmd wifi list-scan-results'"`. Watch the quoting: the inner
> command uses single quotes, so any double quotes inside it need escaping.

### 1. Confirm the failure is an SAE timeout

Try to connect normally, let it fail, then read the failure reason:

```sh
dumpsys wifi | grep -E "level2Failure|networkType"
```

The output is one long line per connection attempt. The fields you care about
are buried in it — here they are pulled out:

```sh
level2FailureCode=AUTHENTICATION_FAILURE
level2FailureReason=AUTH_FAILURE_TIMEOUT
networkType=TYPE_WPA3
durationMillis=10015
```

`networkType=TYPE_WPA3` on a network you configured as WPA2 is the tell — that's
the auto-upgrade creating the broken profile. If you see a different
`level2FailureCode`, this isn't your problem and the script won't help.

If the failure is old, the line you want may have scrolled past. `dumpsys wifi`
keeps a rolling history, so grep for your SSID to find the most recent attempt
for that network specifically.

### 2. Find the BSSID to pin to

Scan and list what's in range. The columns are
`BSSID  frequency  signal  age  SSID  flags`:

```sh
cmd wifi list-scan-results
```

You want a row for your SSID whose flags contain `RSN-PSK` (that's WPA2) and
whose frequency is in the 5 GHz range — 5150–5850 MHz. Ignore rows with
`RSN-SAE` (WPA3) and anything at 5925 MHz or above (6 GHz). The BSSID is the
first column.

If your SSID doesn't appear, the scan cache is stale — toggle Wi-Fi off and on,
or run `cmd wifi start-scan` and wait a few seconds.

### 3. Confirm the AP's security type

```sh
cmd wifi list-networks
```

A mixed-mode SSID shows up **twice** under the same network id — once as
`wpa2-psk` and once as `wpa3-sae^`. That duplicate is the bug in plain sight. The
`^` marks the auto-generated half. Note the id; you'll need it if you want to
forget the network later.

### 4. Try the manual fix

With the BSSID from step 2, run the connect by hand. This is what the script
does on every boot:

```sh
cmd wifi connect-network "MyNetwork" wpa2 <password> -b <bssid> -r auto
```

If that connects, you've confirmed the diagnosis. **It won't survive a reboot** and
the paired profile comes back and the framework re-picks the broken WPA3 half.
**That's what the script automates.**

---

## The script

`thor-wifi.sh` — one file, runs at boot via Magisk's `service.d`, re-issues the
pinned connect automatically. It also picks the AP for you, so you don't need to
hunt for a BSSID.

**Requirements:** rooted Thor with Magisk. `cmd wifi connect-network` is gated
behind `NETWORK_SETTINGS`, which is root-only. Shizuku and Tasker run as UID
2000 and fail with `SecurityException`. There is no non-root fix.

### Install from a computer (adb)

```sh
adb push thor-wifi.sh /data/local/tmp/
adb shell "su -c 'cp /data/local/tmp/thor-wifi.sh /data/adb/service.d/ && \
  chmod 755 /data/adb/service.d/thor-wifi.sh && \
  chown root:root /data/adb/service.d/thor-wifi.sh'"
```

### Install on the Thor itself (no computer)

If you have a terminal app on the device, you can skip the computer entirely.
Download the script straight to the device and install it from a root shell:

```sh
su
curl -fsSL https://raw.githubusercontent.com/MatthewGlenn/ayn-thor-wifi-fix/main/thor-wifi.sh \
  -o /data/local/tmp/thor-wifi.sh
cp /data/local/tmp/thor-wifi.sh /data/adb/service.d/
chmod 755 /data/adb/service.d/thor-wifi.sh
chown root:root /data/adb/service.d/thor-wifi.sh
```

Run `su` **first**, then the rest. The script checks whether it has a terminal
to decide between prompting and running silently, and a non-interactive `su -c`
doesn't give it one — so it would take the boot path instead of asking for your
password. Being inside a root shell avoids that.

### Configure

Run it once by hand. It prompts for your SSID and password, asks which band to
prefer, scans, picks the best AP in that band, and tests the connection:

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --setup'"
```

The band prompt defaults to **5 GHz**. Pick 2.4 GHz if you'd rather have range
than speed — the choice is saved and used on every boot and by `--rediscover`.
5 GHz is preferred regardless of signal strength, so a stronger 2.4 GHz AP won't
win by default.

That's it. Reboot and it connects on its own, in about 2 seconds.

### What it does on boot

1. Waits for boot to complete.
2. Checks Wi-Fi is on and your SSID is in range. If not, it does nothing and
   exits — so it's safe to leave installed when you travel.
3. Connects pinned to the saved BSSID with a randomized MAC.
4. Posts a notification only if it fails.

### Check on it

```sh
# One-line result of the last run
adb shell "su -c 'cat /data/local/tmp/thor-wifi-boot.status'"
```

| Status | Meaning |
|:---|:---|
| `OK: connected to <bssid>` | Connected to the target AP |
| `OK: already on target AP` | Was already there, nothing to do |
| `SKIPPED: <ssid> not in range` | Away from home, did nothing |
| `SKIPPED: wifi disabled` | Wi-Fi was off |
| `SKIPPED: not configured` | No config yet — run setup |
| `FAILED: ...` | Something went wrong; a notification is posted |

The status file is written every time the script runs. If you just installed it
and haven't rebooted yet, the file won't exist — reboot, or run the script once
with no arguments.

### If it stops working after a router reboot

Mesh systems rotate BSSIDs on reboot. Re-pick the AP without re-entering your
password:

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --rediscover'"
```

### Update

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --update'"
```

Fetches the current script, checks it's actually a script, and replaces the
installed copy. Your config and password are left alone. Add `--dry-run` to see
the diff first and change nothing.

The download is not signature-verified — it's fetched over HTTPS from a fixed
URL, the same trust model as the initial install. If that matters to you, use
`--update --dry-run` and read the diff.

### Logging

**Off by default** — a log nobody reads is just a file that grows. Turn it on
if you're debugging:

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --log'"
```

Logs are trimmed to 7 days on each boot. Change that with `--keep-days N`.

Check which version you're running with `--version`.

### Uninstall

The script removes itself — there's no second file to download:

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --uninstall --forget'"
```

`--forget` also removes the saved network profile. Without it, your network is
left alone. Add `--dry-run` first if you want to see the list before anything
is deleted.

---

## Notes

* **The password is stored in plaintext** at `/data/local/thor-wifi/cred`,
  `600 root:root`. This is not a downgrade — Android already stores your Wi-Fi
  passphrase in plaintext in `WifiConfigStore.xml`. There's no `openssl` or
  `gpg` on the device, and a key stored next to the ciphertext is just
  obfuscation. `/data` is file-based encrypted, so the real threat model is an
  unlocked, rooted device.
* **5 GHz WPA2 is the target, not 6 GHz.** 6 GHz on these routers is SAE-only
  with no WPA2 fallback, so it re-triggers bug 1 on every reconnect. 5 GHz WPA2
  gives the same throughput (960–1200 Mbps) without SAE.
* **No firmware fix exists.** Last Wi-Fi fix was v1.0.0.360; current build
  v1.0.0.377 only reverted the Black Theme.
* **The community app `parthi1994/ayn-thor-wifi-recovery` does not fix this.**
  It calls `connect-network` without `-b`, so it hits bug 1 every time. It also
  requires root.
* **Read the script before you run it.** It runs as root on every boot. It's
  short enough to read in one sitting, and that's the only real protection
  against a bad copy.
* **Code written with AI Assistance from DeepSeek.**

Tested on `Thor_V1.0.0.377_20260206_165408_user`, Magisk 30.7.
