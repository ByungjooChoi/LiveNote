# Gemini Model Comparison Test Results
**Date:** 2026-01-27

## Test Environment
- Buffer Mode: generateContent API (folubebe style)
- Buffer Duration: 5.0 seconds
- Audio Source: BlackHole 2ch (48kHz → 16kHz resampled)
- Same audio content used for both tests (recorded meeting)

---

## Test 1: Gemini 3.0 Flash Preview (Simple Prompt)
**Log:** `livenote_20260127_171807.log`
**Duration:** ~2.5 minutes (17:18:07 → 17:20:46)

### Queue Progression (Buffer Backlog)
| Buffer # | Queue Size | Trend |
|----------|------------|-------|
| 1-5 | 1/20 | ✅ Stable |
| 6-7 | 2/20 | ⚠️ Starting to lag |
| 8-13 | 2-3/20 | ⬆️ Growing |
| 14-17 | 3-4/20 | ⬆️ Growing |
| 18-21 | 5-6/20 | ⬆️ Growing |
| 22-25 | 6-7/20 | ⬆️ Growing |
| 26-30 | 7-9/20 | ❌ **Ending at 9/20** |

### Statistics
- **Total Buffers Created:** 30
- **Buffers Processed:** 21
- **Buffers Dropped:** 0
- **Total Data:** 4.48 MB
- **Final Queue Backlog:** 9/20 (45% backed up)
- **Translations Output:** 44 text segments

### Observation
Queue steadily grew from 1 → 9 over 2.5 minutes. Model couldn't keep up with real-time 5-second audio buffers.

---

## Test 2: Gemini 2.0 Flash (Simple Prompt)
**Log:** `livenote_20260127_172135.log`
**Duration:** ~2.5 minutes (17:21:35 → 17:24:xx)

### Queue Progression
| Buffer # | Queue Size | Trend |
|----------|------------|-------|
| 1-5 | 1/20 | ✅ Stable |
| 6-10 | 1/20 | ✅ Stable |
| 11-15 | 1/20 | ✅ Stable |
| 16-20 | 1/20 | ✅ Stable |
| 21-25 | 1/20 | ✅ Stable |
| 26-32 | 1/20 | ✅ **Perfect throughout** |

### Statistics
- **Total Buffers Created:** 32
- **Buffers Processed:** 31
- **Buffers Dropped:** 0
- **Total Data:** 4.77 MB
- **Final Queue Backlog:** 1/20 (0% backed up)
- **Translations Output:** 70 text segments

### Observation
Queue stayed at 1/20 for the **entire session**. Every 5-second buffer was processed before the next one arrived.

---

## Test 3: Gemini 2.5 Flash (Simple Prompt)
**Log:** `livenote_20260127_172748.log`
**Duration:** ~2.5 minutes (17:27:48 → 17:30:xx)

### Queue Progression
| Buffer # | Queue Size | Trend |
|----------|------------|-------|
| 1-5 | 1/20 | ✅ Stable |
| 6-10 | 1/20 | ✅ Stable |
| 11-14 | 1/20 | ✅ Stable |
| 15-16 | 1-2/20 | ⚠️ Brief spike |
| 17-18 | 1-2/20 | ⚠️ Brief spike |
| 19-26 | 2-3/20 | ⚠️ Slight lag |
| 27-33 | 1-2/20 | ✅ Recovering |

### Statistics
- **Total Buffers Created:** 33
- **Buffers Processed:** 32
- **Buffers Dropped:** 0
- **Total Data:** 4.98 MB
- **Final Queue Backlog:** 1/20 (recovered)
- **Translations Output:** 70 text segments

### Observation
Queue occasionally spiked to 2-3/20 mid-session but recovered. Not as consistent as 2.0, but still real-time capable.

---

## Head-to-Head Comparison

| Metric | 3.0 Flash | 2.5 Flash | 2.0 Flash | Winner |
|--------|-----------|-----------|-----------|--------|
| **Model** | gemini-3-flash-preview | gemini-2.5-flash | gemini-2.0-flash | - |
| **Buffers Created** | 30 | 33 | 32 | - |
| **Buffers Processed** | 21 | 32 | 31 | 🏆 2.5/2.0 |
| **Queue Stability** | 1→9 (growing) | 1-3 (minor spikes) | 1 (constant) | 🏆 2.0 |
| **Final Backlog** | 9 buffers (45s) | 1 buffer | 0 buffers | 🏆 2.0 |
| **Real-time Capable** | ❌ No | ✅ Yes | ✅ Yes | 🏆 2.5/2.0 |
| **Translations Output** | 44 | 70 | 70 | 🏆 2.5/2.0 |
| **Avg Processing Time** | ~7-8s | ~5-6s | <5s | 🏆 2.0 |

---

## Key Finding

**Processing time comparison per 5-second buffer:**

| Model | Avg Processing Time | Real-time? |
|-------|---------------------|------------|
| 3.0 Flash | ~7-8 seconds | ❌ Falls behind |
| 2.5 Flash | ~5-6 seconds | ✅ Marginal (occasional lag) |
| 2.0 Flash | <5 seconds | ✅ Perfect |

At Buffer #30:
- **3.0:** Processing #21 (9 buffers behind = 45 seconds of lag)
- **2.5:** Processing #28-29 (1-2 buffers behind = 5-10 seconds of lag)
- **2.0:** Processing #30-31 (0 buffers behind = real-time)

---

## Conclusion

**Gemini 2.0 Flash remains the best choice for real-time translation.**

| Model | Verdict |
|-------|---------|
| **2.0 Flash** | 🏆 Best - Perfect real-time, no lag |
| **2.5 Flash** | ✅ Good - Real-time capable with minor occasional spikes |
| **3.0 Flash** | ❌ Not ready - Falls behind consistently |

### Recommendation
- **Production:** Use `gemini-2.0-flash` for guaranteed real-time performance
- **Alternative:** `gemini-2.5-flash` is acceptable if you need newer model features
- **Avoid:** `gemini-3-flash-preview` until it exits preview and improves latency
