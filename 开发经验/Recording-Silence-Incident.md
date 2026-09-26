# Incident Plan — Long-Form Recording Delivers Silence

> A reference for the next time this breaks. It records what happened, which
> commit the working state corresponds to, and — the part that matters most —
> **which angle to come at it from**, so the next investigation starts where this
> one ended instead of repeating it.

Date written: 2026-09-26
Status: **resolved by rebinding; the underlying weakness is NOT fixed.**
See §7.

---

## 1. Reference node — when recording last fully worked

If you need a known-good point to compare against, this is the one.

| | |
|---|---|
| **Wall clock** | 2026-09-26 **02:51 local** (2026-09-25 18:51:30 UTC) |
| **Recording id** | `2026-09-26-025130-97F3` |
| **Commit in the tree at that time** | `4e9e085` — *Record where a click actually resolves* (committed 02:51) |
| **Evidence it was healthy** | declared input format **1 channel**, block-50 peak **1276** |

The measurement that defines "working" is two numbers from the diagnostic log,
and both must be checked — either one alone is misleading:

```
引擎声明的输入格式 采样率=48000.0 声道=1   ← 1 channel, matching the hardware mic
第 50 块：… 峰值=1276/32768               ← non-zero audio actually arriving
```

**Caveat, and it is an important one:** the commit timeline turned out **not** to
explain this incident. Recording was healthy at `4e9e085` (02:51), the first
silent run was at 08:25, and five commits landed in between (08:17–08:24) — but
none of them touch audio, and the eventual cause was not in the code at all. The
commit node is recorded here because it is useful as a "last known good" anchor,
**not because a regression was found there.**

---

## 2. The symptom

The user reported it in one line: recording does not record, there is no
transcript, and no text appears under the notch.

The log told a more specific story:

```
开始录音 2026-09-26-082553-9A75 · 判重窗口 0ms
引擎声明的输入格式 采样率=48000.0 声道=3      ← 3 channels; no device has 3
第 1 块：1360 帧 峰值=0/32768 (0.000) 累计零块=1/1
第 50 块：峰值=0  累计零块=50/50
…
第 500 块：峰值=0 累计零块=500/500            ← every block silent
服务端错误帧 code=45000081 {"error":"[Timeout waiting next packet]
  waiting next packet timeout: 8.000000 seconds, session has ended"}
看门狗：已 19 秒没有任何回包，判定连接已死     ← ×10 reconnects
录音结束：0 字，117.1 秒
```

Three things are worth noticing, because each one misled the investigation at
some point:

1. **The server error is a symptom, not the cause.** `Timeout waiting next
   packet` means the server received no audio — it is reporting our silence back
   to us. The connection dying and reconnecting is downstream of that.
2. **`0 字` is the last link in the chain.** The empty transcript is what the user
   sees; it says nothing about why.
3. **The channel count was the first real clue — and it was also a dead end.**
   The engine reported 3; every device on the machine reports 1 or 2. A count
   nothing possesses says the engine is bound to something that is not a device.

---

## 3. Root cause

The engine is bound to **`CADefaultDeviceAggregate`** — CoreAudio's dynamic
default-device aggregate — rather than to the microphone itself.

Confirmed by the instrument added in `4663d39`, whose first run printed:

```
引擎声明的输入格式 采样率=48000.0 声道=1 · 设备=CADefaultDeviceAggregate-48143-0 [id=144]
```

Why that produces silence: the aggregate is **assembled by macOS from whatever
devices currently exist**, so it is rebuilt whenever devices come and go. This
machine has two candidates to react to:

```
MacBook Pro麦克风      1 in   0 out   Apple
MacBook Pro扬声器      0 in   2 out   Apple
iShotAudioPlugin      2 in   2 out   Existential Audio   ← Transport: Virtual
```

`iShot Pro` (pid 22776 at the time) was running with its Core Audio driver
loaded. A freshly rebuilt aggregate hands out silence until its members are ready,
and its channel count follows its membership — which is where the 3 comes from.

**Rel launching the app rebinds and it records again.** Verified twice:

| Time (local) | Channels | Block-50 peak | Transcript |
|---|---|---|---|
| 08:34 | 1 | 522 | 41 characters, 9.1 s |
| 08:34 | 1 | — | 57 characters, 8.3 s |

---

## 4. What made this hard, and the method that found it

Worth reading before the next one, because the same shape will recur.

**The failure is completely silent.** No exception, no error, no non-zero exit.
The tap fires on schedule, the files are written, the UI behaves — the audio is
just zeros. Everything reports success.

**Two hypotheses were formed from the evidence and both were wrong:**

| Hypothesis | How it was tested | Result |
|---|---|---|
| The connection/watchdog is at fault | Checked the log for earlier occurrences | **Refuted** — the watchdog also fired during sessions that produced 298 characters |
| Voice-processing (VPIO) on the shared engine is holding the input device | Set `echoCancellationEnabled = false`, recorded again, single variable | **Refuted** — still 3 channels, still silent. Setting restored to `true` |

Both were plausible readings of the same evidence. Neither survived a
measurement. **This is why the rule in `CLAUDE.md` — instrument, do not guess —
is not a formality.**

**What actually worked was adding one dimension to the log.** The recorder
already printed the *format* and even counted silent blocks (`累计零块`), and its
own comment anticipated this exact failure ("被别的进程占着"). What it never
printed was **which device it bound to**. One line, and the answer was immediate.

> **The generalisable lesson.** When a log tells you a *shape* but not an
> *identity*, you have an instrument missing a dimension, and every hypothesis
> you form will be consistent with the evidence you have. The click-path incident
> in this repository was the same shape: three distinct failures produced one
> symptom, and one added log line collapsed them into one.

---

## 5. The angles to come at it from, if it recurs

Ordered by what to check first. **Do not skip to hypotheses — start at step 1.**

### Step 1 — Read the two numbers, in the log

```
~/Library/Application Support/Wanna/录音诊断.log
```

```bash
grep -E "输入格式|峰值=|录音结束" ~/Library/Application\ Support/Wanna/录音诊断.log | tail -20
```

| What you see | What it means | Go to |
|---|---|---|
| `声道=1` and non-zero peak | Audio is fine; the problem is downstream (ASR, network, commit) | Step 4 |
| Any channel count, `峰值=0` | **This incident.** Silence at the input | Step 2 |
| `声道=0` | No device or no permission | Step 3 |
| `录音结束：N 字` but the notch shows nothing | Storage/display, not capture | Step 5 |

The channel count is the tell. **Compare it against the hardware:**

```bash
system_profiler SPAudioDataType | grep -E "^\s+\S.*:$|Input Channels|Manufacturer|Transport"
```

`声道=1` for the built-in mic is the healthy value. **A count that no device on
the machine has means the engine is bound to an aggregate, not a device.**

### Step 2 — Ask which device it bound to

Since `4663d39` the log already answers this:

```
· 设备=CADefaultDeviceAggregate-48143-0 [id=144]
```

- **`CADefaultDeviceAggregate-*`** → this is the failure. Go to Step 3.
- A named device (e.g. `MacBook Pro麦克风`) → the binding is right, so the
  silence comes from elsewhere: check for a hardware mute, another process
  holding the device, or physical input selection.

### Step 3 — Look for device churn

The aggregate is rebuilt when devices appear or disappear. Check what is loaded
and what is running:

```bash
ps -eo pid,comm | grep -iE "ishot|loopback|blackhole|audio"
system_profiler SPAudioDataType | grep -iE "virtual|aggregate|existential"
```

Any virtual driver (this machine has `iShotAudioPlugin` from iShot Pro) is a
candidate. **The immediate workaround is to relaunch Wanna** — it rebinds and
records again. Confirm with §1's two numbers.

### Step 4 — Only now consider the code

If the input is healthy, the remaining candidates are the ASR connection, the
upload path, or the transcript writer. `开发经验/10-踩过的坑.md` and
`开发经验/01-语音打断与持续监听.md` cover the known ones.

### Step 5 — If the text is missing but the transcript is not

The file on disk is the truth:

```bash
ls -la ~/Desktop/Wanna录音/<session-id>.*
```

A non-zero `.txt` with nothing on screen is a display problem, not a capture one.

### The question to ask first, every time

> **Does the microphone deliver non-zero samples?**

Everything else in this subsystem is downstream of that one fact, and it is one
`grep` away. Both wrong hypotheses in §4 were formed without checking it first.

---

## 6. What counts as evidence here

- **`峰值=` (peak) is the audio-arrival measurement.** Zero across hundreds of
  blocks is silence, not a quiet room — a quiet room still measures a non-zero
  floor (this repository measured an ambient floor peaking at 0.167 on its own
  scale).
- **`声道=` (channel count) is the binding measurement.** It changes with the
  device the engine is bound to.
- **`累计零块` (cumulative silent blocks) was already being counted** and nobody
  read it. It is a ready-made alarm: N consecutive silent blocks means the input
  is dead, and the app could say so on screen instead of recording 117 seconds of
  nothing.
- **`录音结束：0 字，<duration> 秒`** — a long duration with zero characters is
  the signature. A *short* recording with zero characters is usually benign (the
  speaker said almost nothing; the server produced no definite segment).

---

## 6b. The real fix — bind to the device, not the aggregate

**Added 2026-09-26, after the requirement was stated plainly: the screen recorder
is used at high frequency and must run *at the same time* as Wanna.**

That rules out every "quit the other app" answer and identifies the actual fault.
`AVAudioEngine.inputNode` follows CoreAudio's **default-device aggregate**
(`CADefaultDeviceAggregate-<pid>-0`), which macOS assembles from whatever devices
exist at that moment, once per process. Its channel count therefore varies:

| Devices present | Aggregate | Result |
|---|---|---|
| microphone alone | 1 channel | works |
| microphone + a recorder's 2-channel virtual driver | **3 channels** | **pure silence** |

Measured: the healthy runs bound `[id=144]` at 1 channel; the silent run bound
`[id=207]` at **3 channels with peak identically 0**.

**The fix** is to pin `kAudioOutputUnitProperty_CurrentDevice` on the input node
to `kAudioHardwarePropertyDefaultInputDevice` — the *real* device — before the
format is read. The format then equals that device's, whatever aggregates exist
beside it.

**Verified under the failing condition**: with iShot Pro running, its helper, and
its 2-channel virtual driver all present in the device list, the engine now
reports `MacBook Pro麦克风 [id=88]` — 1 channel, peak 237, 24 characters
transcribed.

**If this recurs**, the first thing to read is the `设备=` field. A named device
means this is not the cause; `CADefaultDeviceAggregate-*` means the pinning did
not take effect.

---

## 6c. The user-facing half — a device setting, and an alarm

**Added 2026-09-26, at the user's request: "let the user set a default device and
see it".** Both halves matter, and they are different things.

**The picker** (设置 → 录音 → 麦克风) lists every input device the machine has,
marks the system default, and stores the **UID** rather than the `AudioDeviceID` —
the id is a session-local number that changes across a reboot or a replug, the UID
is the device's identity.

Two corrections came out of the user's own screenshot of the first version:

- **Aggregate devices must not be listed at all.** The first filter was "has input
  channels", and a healthy aggregate has one — so `CADefaultDeviceAggregate`
  appeared as a choice, which is the single selection that reinstates the fault.
  The predicate is transport type, not channel count: an aggregate is
  categorically not a device.
- **Virtual devices stay, labelled.** Unlike an aggregate they can be a legitimate
  choice (a loopback is how one captures system audio), so the judgement belongs
  to the user and the label is what makes it possible.

**The readout** — 「这一场实际用的」 — shows which device the *last* recording
actually bound to. It is deliberately separate from the picker: a device can be
unplugged or held by another process, so what was chosen and what was used are
different facts, and only the second one explains a silent recording.

**The alarm.** Ten consecutive silent blocks (~10 s) now produce a line in the log
and a row on the settings page. The counter for this already existed and nobody
read it. This matters independently of the cause: the failure is silent in every
direction — the tap fires, files are written, the UI behaves — so without an alarm
the first signal is that nothing is being transcribed, discovered after 117 s.

**Not done, deliberately:** rebinding mid-recording when a device is unplugged or
plugged in. Capture binds once at the start and falls back to the default if the
chosen device has gone (saying so in the log). Mid-session rebinding means
reconfiguring a running `AVAudioEngine`, which should be measured before it is
changed — and the reported problem (a screen recorder running alongside) is solved
without it.

---

## 7. What is fixed, and what is not

**Fixed (this incident):**

- `4663d39` adds the device name to the log line. This is what identified the
  cause, and it is the reason the next occurrence starts at §5 Step 2 rather than
  at the beginning.
- Recording is working now, verified twice (§3).

**NOT fixed — the weakness remains:**

**The long-form recorder does not handle input-device changes.** Any device
churn — plugging in headphones, iShot Pro starting or stopping, a virtual device
appearing — can silently turn a recording into zero characters with no error
anywhere, exactly as happened here. Relaunching is a workaround, not a fix.

Candidate fixes, none implemented, listed with their costs:

| Approach | Cost |
|---|---|
| **Surface it.** The app already counts `累计零块`; after N consecutive silent blocks, say so on screen instead of recording silence. | Small. Does not prevent the failure — makes it visible, which is the difference between a 117-second loss and a 2-second one. |
| **Detect and rebind.** Observe default-device changes (`AudioObjectAddPropertyListener` on `kAudioHardwarePropertyDefaultInputDevice`) and rebuild the engine's binding. | Medium. The correct fix. |
| **Pin the device.** Bind explicitly to the built-in microphone instead of the default aggregate. | Small, but wrong for anyone with an external mic — the user's choice of input device is theirs. |

The first is worth doing regardless: the other two are about stopping the
failure, and this one is about never again losing two minutes to something with
no error message.

---

## 8. Timeline, for reference

| Time (local) | Event |
|---|---|
| 2026-09-26 02:51 | **Last healthy recording** — 1 channel, peak 1276. Commit `4e9e085` in the tree. |
| 03:02 | `1de9e67` — MCP logging. |
| 08:17–08:24 | `868b462`, `b017dc0`, `b687f75`, `9d16f1c`, `46ad0d0` — agent strip, panel, setting, catalogue fixes. **None touch audio.** |
| 08:25 | **First silent recording** — 3 channels, peak 0, 117.1 s, 0 characters, 10 reconnects. |
| 08:29 | Reproduced deliberately by sending the recording shortcut (⌃A); VPIO hypothesis tested and refuted. |
| 08:34 | `4663d39` adds the device name. First run prints `CADefaultDeviceAggregate-48143-0`. Relaunch rebinds; **41 characters, then 57**. |
