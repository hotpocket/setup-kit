---
tags: [session, thermal, zenbuntu]
type: session
concerns: [ops, infra, hardware]
audience: []
summary: "Forensics on Zenbuntu's (Zenbook UX3405MA, 155H) 2026-07-09 hard power-off under sustained TTS: hardware healthy — fan ramps 1900→5100 RPM with ~50s hysteresis (balanced profile caps ~3700), 100°C-in-seconds is Meteor Lake boost-to-ceiling, cores hold 4.4-4.6 GHz at Tjmax. Root cause: Linux leaves RAPL PL1 at 200 W (no Intel DTT; thermald --adaptive not enforcing firmware tables), so temperature is the only limiter → chassis soak → EC cut. Fix: epp-balance-power.service sets EPP balance_performance + PL1 22W/PL2 35W at boot. Measured: TTS RTF 1.69x @ 74-90°C (28W identical at 1.70x — bandwidth-bound; balance_power 2.06x; uncapped 1.48x @ 100°C pinned). Warranty moot (Best Buy unit, expired 2025-03-02). Deep-research: cooling pads/risers ranked; vacuum coolers snake oil; PTM7950 unnecessary."
created: 2026-07-10
status: completed
projects: [setup-kit]
branch: main
---

# Zenbuntu thermal forensics + RAPL/EPP defaults

## The crash (2026-07-09 13:05)
~40 min of 16-thread chatterbox TTS in `balanced` profile → package rode 100 °C
(kernel throttle events, NVMe timeout) → chassis/VRM soak → EC hard power-cut.
Journal ends mid-line; no panic, no OOM.

## Forensics (wargamed after a false "defective cooling" diagnosis)
- Fan healthy: EC ramps 1900→5100 RPM, ~50 s hysteresis; `balanced` platform
  profile caps ~3700 RPM (performance profile uses full range).
- 100 °C in seconds at 2 threads = Meteor Lake boost-to-ceiling **by design**;
  loaded cores sustain 4.4–4.6 GHz at Tjmax → paste/heatpipe fine. Short test
  windows (≤25 s) had masked the slow fan ramp — measure ≥3 min.
- **Root cause: RAPL PL1 = 200 W** (firmware sentinel; ASUS expects Windows
  Intel DTT to manage power — instrumented reviews show ~28 W sustained there).
  On Linux, `thermald --adaptive` runs but doesn't enforce the DTT tables on
  this model, so *temperature* was the only limiter.

## Fix (this box, /etc/systemd/system/epp-balance-power.service)
Oneshot at boot (After=power-profiles-daemon): EPP `balance_performance` on all
policies + PL1 22 W / PL2 35 W. Power is now the limiter; temps 74–90 °C under
sustained load. Note: ppd profile switches reset EPP until the unit is rerun.

Measured (chatterbox TTS, 16 threads, 6-chunk bench, ~/.venvs/chatterbox-xpu):
| config | RTF | temps |
|---|---|---|
| uncapped + balance_performance | 1.48x | 100 °C pinned (crashy) |
| **22 W + balance_performance** | **1.69x** | 74–90 °C |
| 28 W + balance_performance | 1.70x | to 93 °C (no gain — bandwidth-bound) |
| balance_power (EPP only) | 2.06x | 62–70 °C |

Also: XPU (Arc iGPU, torch 2.13+xpu) works but is *slower* than CPU (~2.0x);
CPU is the emergency-TTS path. PyTorch's 16 threads = 1 per physical core
(idle SMT siblings in monitors are correct behavior).

## Cooling products (deep-research, measured-deltas only)
Rear elevation ~5–8 °C ($0–25, measured on this SKU); IETS GT300 pad ~3–8 °C
(~$60, 14" sealing ring); skip vacuum clip-on coolers (worst category in
controlled tests; no side vent to seal) and PTM7950 repaste (TIM proven fine).

## TODO candidates
- [ ] Codify the RAPL/EPP unit as a setup-kit component (laptop profile boxes
      without DTT) — see [[thermal-caps component]] sketch.
- [ ] Zenbuntu hygiene: `fwupdmgr update` (dbx) + BIOS 308→311 (ASUS site).
