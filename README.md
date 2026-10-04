# AYN Thor — Wi-Fi won't connect to a WPA2/WPA3 mixed-mode network

**TL;DR:** The Thor fails to connect to WiFi networks sometimes and throws an authentication error. This is related to networks that present WPA2 and WPA3 at the same time (my router 😭). Pinning the BSSID fixes it. This script does it automatically on every boot. **Root required.**

**Code and documentation written with AI Assistance from DeepSeek.**

Tested on `Thor_V1.0.0.377_20260206_165408_user` with Magisk 30.7.

### Quick start

**On the Thor** (terminal app, no computer needed):

Open your terminal app and get a root shell:

```sh
su
```

Download the script:

```sh
curl -fsSL https://raw.githubusercontent.com/MatthewGlenn/ayn-thor-wifi-fix/main/thor-wifi.sh \
  -o /data/local/tmp/thor-wifi.sh
```

Install it as a boot script:

```sh
cp /data/local/tmp/thor-wifi.sh /data/adb/service.d/ && \
  chmod 755 /data/adb/service.d/thor-wifi.sh && \
  chown root:root /data/adb/service.d/thor-wifi.sh
```

Configure it (prompts for SSID, password and band):

```sh
sh /data/adb/service.d/thor-wifi.sh --setup
```

**From adb on a computer**:

Download the script to your computer first if you haven't already and place it in your current working directory.

You'll need to have `adb` installed and properly configured on your computer.

These commands should work on any modern Linux, macOS, or Windows machine with `adb` installed.

Push the script to the device:

```sh
adb push thor-wifi.sh /data/local/tmp/
```

Install it as a boot script:

```sh
adb shell "su -c 'cp /data/local/tmp/thor-wifi.sh /data/adb/service.d/ && \
  chmod 755 /data/adb/service.d/thor-wifi.sh && \
  chown root:root /data/adb/service.d/thor-wifi.sh'"
```

Configure it (prompts for SSID, password and band):

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --setup'"
```

`--setup` prompts for your SSID (network name), password and band, then tests the connection.
When you reboot, it will connect on its own. No more network amnesia!

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

### 1. Confirm the failure is an SAE timeout

Try to connect normally, let it fail, then read the failure reason.

**On the Thor:**

```sh
dumpsys wifi | grep -E "level2Failure|networkType"
```

**From adb on a computer:**

```sh
adb shell "su -c 'dumpsys wifi | grep -E \"level2Failure|networkType\"'"
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
`BSSID  frequency  signal  age  SSID  flags`.

**On the Thor:**

```sh
cmd wifi list-scan-results
```

**From adb on a computer:**

```sh
adb shell "su -c 'cmd wifi list-scan-results'"
```

You want a row for your SSID whose flags contain `RSN-PSK` (that's WPA2) and
whose frequency is in the 5 GHz range — 5150–5850 MHz. Ignore rows with
`RSN-SAE` (WPA3) and anything at 5925 MHz or above (6 GHz). The BSSID is the
first column.

If your SSID doesn't appear, the scan cache is stale — toggle Wi-Fi off and on,
or run `cmd wifi start-scan` and wait a few seconds.

### 3. Confirm the AP's security type

**On the Thor:**

```sh
cmd wifi list-networks
```

**From adb on a computer:**

```sh
adb shell "su -c 'cmd wifi list-networks'"
```

A mixed-mode SSID shows up **twice** under the same network id — once as
`wpa2-psk` and once as `wpa3-sae^`. That duplicate is the bug in plain sight. The
`^` marks the auto-generated half. Note the id; you'll need it if you want to
forget the network later.

### 4. Try the manual fix

With the BSSID from step 2, run the connect by hand. This is what the script
does on every boot.

**On the Thor:**

```sh
cmd wifi connect-network "MyNetwork" wpa2 <password> -b <bssid> -r auto
```

**From adb on a computer:**

```sh
adb shell "su -c 'cmd wifi connect-network \"MyNetwork\" wpa2 <password> -b <bssid> -r auto'"
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
2000 and fail with `SecurityException`. **There is no non-root fix that I am aware of.**

### Install on the Thor itself (no computer)

If you have a terminal app on the device, you can skip the computer entirely.

Get a root shell:

```sh
su
```

Download the script straight to the device:

```sh
curl -fsSL https://raw.githubusercontent.com/MatthewGlenn/ayn-thor-wifi-fix/main/thor-wifi.sh \
  -o /data/local/tmp/thor-wifi.sh
```

Install it as a boot script:

```sh
cp /data/local/tmp/thor-wifi.sh /data/adb/service.d/ && \
  chmod 755 /data/adb/service.d/thor-wifi.sh && \
  chown root:root /data/adb/service.d/thor-wifi.sh
```

Run `su` **first**, then the rest. The script checks whether it has a terminal
to decide between prompting and running silently, and a non-interactive `su -c`
doesn't give it one — so it would take the boot path instead of asking for your
password. Being inside a root shell avoids that.

### Install from a computer (adb)

Download the script to your computer:

```sh
curl -fsSL https://raw.githubusercontent.com/MatthewGlenn/ayn-thor-wifi-fix/main/thor-wifi.sh \
  -o thor-wifi.sh
```

Push it to the device:

```sh
adb push thor-wifi.sh /data/local/tmp/
```

Install it as a boot script:

```sh
adb shell "su -c 'cp /data/local/tmp/thor-wifi.sh /data/adb/service.d/ && \
  chmod 755 /data/adb/service.d/thor-wifi.sh && \
  chown root:root /data/adb/service.d/thor-wifi.sh'"
```

### Configure

Run it once by hand. It prompts for your SSID and password, asks which band to
prefer, scans, picks the best AP in that band, and tests the connection.

**On the Thor:**

```sh
su
sh /data/adb/service.d/thor-wifi.sh --setup
```

`su` first. The script needs a terminal to prompt, and a non-interactive `su -c`
doesn't provide one — it would take the boot path and exit without asking you
anything.

**From adb on a computer:**

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --setup'"
```

Run this one on the device if you can — the prompt is interactive, and the adb
form only works cleanly when your terminal forwards stdin.

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

### If setup says it failed

The script reads the supplicant log to tell you which of two things went wrong,
because they look identical from the outside:

* **`The password was rejected (ERROR_AUTH_FAILURE_WRONG_PSWD).`** — the
  password is wrong. Re-run `--setup` and check it. This is the common one, and
  it is easy to hit because the prompt hides what you type.
* **`The access point may have blacklisted this device's MAC.`** — the password
  was accepted but the router stopped answering. Reboot the router, then run
  `--setup` again.

If you are not sure which you hit, check the log directly:

```sh
su -c 'dumpsys wifi | grep -o "AUTHENTICATION_FAILURE_EVENT reason=[0-9]*:[A-Z_]*"'
```

`ERROR_AUTH_FAILURE_WRONG_PSWD` means the password. Anything else, or no output
at all, points at the router.

### If it stops working after a router reboot

Mesh systems rotate BSSIDs on reboot. Re-pick the AP without re-entering your
password.

**On the Thor:**

```sh
su
sh /data/adb/service.d/thor-wifi.sh --rediscover
```

**From adb on a computer:**

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --rediscover'"
```

### Uninstall

**On the Thor:**

```sh
su
sh /data/adb/service.d/thor-wifi.sh --uninstall --forget
```

**From adb on a computer:**

```sh
adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --uninstall --forget'"
```

`--forget` also removes the saved network profile. Without it, your network is
left alone. Add `--dry-run` first if you want to see the list before anything
is deleted.

---

## Notes

* **The password is stored in plaintext** at `/data/local/thor-wifi/cred`,
  `600 root:root`. Android already stores your Wi-Fi passphrase in plaintext in
  `WifiConfigStore.xml`. I wanted to try encrypting it, but there's no `openssl`
  or `gpg` on the device, and a key stored next to the ciphertext doesn't really
  solve the problem. `/data` is file-based encrypted, so the real threat model is
  an unlocked, rooted device.
* **5 GHz WPA2 is the target, not 6 GHz.** 6 GHz on these routers is SAE-only
  with no WPA2 fallback, so it re-triggers bug 1 on every reconnect. 5 GHz WPA2
  gives the same throughput (960–1200 Mbps) without SAE.
* **No firmware fix currently exists.** Last Wi-Fi fix was v1.0.0.360.
* **Read the script before you run it.** It runs as root on every boot. So be sure you understand what it does.
