# CDCKIT — Clock Domain Crossing Toolkit
## Hardware Architecture Specification (HAS) & Micro-Architecture Specification (MAS)

| Field | Value |
|---|---|
| Document | CDCKIT-SPEC-001 |
| IP | `cdckit` — Library of CDC primitives + parameterizable asynchronous FIFO |
| Document version | 0.7 (Draft) |
| IP version | 1.0 (target) |
| Date | 2026-10-29 |
| Parent project | NetSwitch-4 — MAC ↔ core interface block |
| Reference platform | AMD Vivado ML Standard Edition (free) · Artix-7 `xc7a100tcsg324-1` |

---

## Table of contents

**Part I — Hardware Architecture Specification (HAS)**

1. [Introduction](#1-introduction)
2. [Feature summary](#2-feature-summary)
3. [Functional description](#3-functional-description)
4. [Hardware interfaces](#4-hardware-interfaces)
5. [Configuration parameters](#5-configuration-parameters)
6. [Clocks and resets](#6-clocks-and-resets)
7. [Performance and latency](#7-performance-and-latency)
8. [Integration requirements](#8-integration-requirements)

**Part II — Micro-Architecture Specification (MAS)**

9. [Module hierarchy](#9-module-hierarchy)
10. [`cdckit_sync`](#10-cdckit_sync--level-synchronizer)
11. [`cdckit_rst_sync`](#11-cdckit_rst_sync--reset-synchronizer)
12. [`cdckit_pulse_sync`](#12-cdckit_pulse_sync--pulse-synchronizer-toggle)
13. [`cdckit_hs`](#13-cdckit_hs--multibit-transfer-via-4-phase-handshake)
14. [`cdckit_afifo`](#14-cdckit_afifo--asynchronous-fifo)
15. [CDC intent and crossing table](#15-cdc-intent-and-crossing-table)
16. [Timing constraints (XDC)](#16-timing-constraints-xdc)
17. [Design assertions](#17-design-assertions)
18. [Resources, power and ASIC portability](#18-resources-power-and-asic-portability)
19. [Requirements traceability matrix](#19-requirements-traceability-matrix)
20. [Open issues](#20-open-issues)

**Annexes**

- [A. MTBF analysis](#annex-a--mtbf-analysis)
- [B. Reference integration: 64-bit counter snapshot](#annex-b--reference-integration-64-bit-counter-snapshot)
- [C. Glossary](#annex-c--glossary)
- [D. References](#annex-d--references)

---

## Document conventions

**Signal naming.**

| Suffix / prefix | Meaning |
|---|---|
| `_i` / `_o` | Module input / output. |
| `_ni` / `_no` | Active-low input / output. |
| `_q` | Register (flip-flop) output. |
| `_d` | Register D input (next value). |
| `current_state` / `nxt_state` | FSM state register / next-state value (used instead of `_q` / `_d` for FSMs). |
| `w*` / `r*` | FIFO write / read domain. |
| `src_*` / `dst_*` | Source / destination domain. |

**Units.** `T_x` denotes the period of clock `x`. Latencies are expressed in active (rising) edges of the indicated clock.

**Requirement keywords.** MUST, MUST NOT, SHOULD and MAY are used as defined in RFC 2119.

---

# PART I — HARDWARE ARCHITECTURE SPECIFICATION

## 1. Introduction

### 1.1 Scope

`cdckit` is a library of five synthesizable primitives for safely transferring information between clock domains with no frequency or phase relationship:

| Module | Signal class it carries |
|---|---|
| `cdckit_sync` | 1-bit level, or mutually independent bits. |
| `cdckit_rst_sync` | Asynchronous reset into a clock domain. |
| `cdckit_pulse_sync` | Single-cycle events (pulses). |
| `cdckit_hs` | Sporadic multibit word (configuration, snapshots). |
| `cdckit_afifo` | Continuous stream of multibit words. |

**Out of scope for version 1.0:**

- Asynchronous FIFO on Block RAM (v1.0 uses distributed RAM, LUTRAM, only; see OI-01).
- Non-power-of-2 depths.
- Data-width conversion between ports.
- ECC or parity protection of the memory.
- Independent single-domain reset of the FIFO (see §6.3 and OI-02).
- ASIC implementation. The RTL is kept portable (DFT and isolation requirements as informative, §18.3), but v1.0 is only verified and implemented on FPGA.
- Formal verification (the reference platform does not include a formal engine; see OI-08).

### 1.2 System context

In NetSwitch-4, `cdckit_afifo` decouples each MAC RX (recovered clock at 156.25 MHz, ±100 ppm) from the core (250 MHz). The remaining primitives carry link status, flow-control events and counter snapshots to the configuration domain (100 MHz).

![NetSwitch-4 system context](img/fig01_system_context.png)
*Figure 1 — Use of `cdckit` in NetSwitch-4.*

### 1.3 Reference configuration

Unless stated otherwise, the figures in this document use the NetSwitch-4 reference configuration:

| Parameter | Value |
|---|---|
| `DATA_W` (FIFO) | 72 (64 b of data + 8 b of `tkeep` / `tlast` / `tuser`) |
| `DEPTH` | 32 |
| `NUM_STAGES` | 2 |
| `wclk` | 156.25 MHz (T = 6.4 ns) |
| `rclk` | 250 MHz (T = 4.0 ns) |
| Device | Artix-7 `xc7a100tcsg324-1` (speed grade -1) |
| Tools | Vivado ML Standard Edition 2025.1 |

---

## 2. Feature summary

- Five CDC primitives with a structure recognizable by Vivado `report_cdc` (synchronizers marked with `ASYNC_REG`) and by commercial CDC tools.
- All synchronizers are implemented through **a single primitive** (`cdckit_sync`). This allows replacing it with Vivado's `xpm_cdc_array_single` macro, or with a library synchronizer cell in ASIC, without modifying the rest of the RTL.
- Configurable number of synchronization stages (2 to 4).
- Reset synchronizer with asynchronous assertion and synchronous deassertion.
- Toggle-based pulse synchronizer, with no combinational path between domains.
- Multibit transfer through a 4-phase handshake with a valid/ready interface on the source side and a holding register.
- Asynchronous FIFO:
  - **registered** Gray pointers synchronized to the opposite domain;
  - *first-word fall-through* (FWFT) semantics;
  - conservative `full` / `empty` flags, guaranteed free of overflow and underflow;
  - `almost_full` / `almost_empty` thresholds programmable by parameter;
  - per-domain occupancy counters;
  - `overflow` / `underflow` indicators (write attempt with the FIFO full, or read attempt with the FIFO empty);
  - option to force `rd_data_o` to zero when the FIFO is empty.
- Sustained throughput of 1 word per cycle on both ports.
- Embedded SVA assertions (disabled in synthesis) for the critical invariants.
- CDC crossing table, expected `report_cdc` classification and intent for module-scoped XDC constraints (§16).
- Documented equivalence with Vivado XPM macros, which serve as the resource and Fmax reference (Table 8-1).

---

## 3. Functional description

### 3.1 IP block diagram

![IP composition](img/fig02_ip_composition.png)
*Figure 2 — IP composition. All synchronization goes through `cdckit_sync`.*

### 3.2 Primitive selection

The IP does not decide which primitive to use; that decision belongs to the integrator. Table 3-1 is the normative selection guide.

| Signal characteristic | Primitive | Usage restriction |
|---|---|---|
| 1-bit level, slowly changing relative to `clk_dst` | `cdckit_sync` (`WIDTH=1`) | The signal MUST come from a flip-flop in the source domain. |
| Several mutually **independent** bits | `cdckit_sync` (`WIDTH=N`) | MUST NOT be used if the bits are interpreted together. |
| Single-cycle event | `cdckit_pulse_sync` | Minimum spacing between events (PERF-003). |
| Sporadic multibit word | `cdckit_hs` | Rate ≤ 1 / T_hs (PERF-004). |
| Continuous multibit stream | `cdckit_afifo` | — |
| Asynchronous reset | `cdckit_rst_sync` | One instance per clock domain. |

*Table 3-1 — Primitive selection by signal class.*

### 3.3 Functional requirements

| ID | Requirement |
|---|---|
| FUNC-001 | Every signal that crosses between domains inside `cdckit` MUST pass through an instance of `cdckit_sync`. |
| FUNC-002 | `cdckit_sync` MUST NOT contain combinational logic between its stages. |
| FUNC-003 | `cdckit_rst_sync` MUST propagate reset assertion without depending on `clk_i` and MUST release the reset synchronized to `clk_i` after `NUM_STAGES` edges. |
| FUNC-004 | `cdckit_pulse_sync` MUST generate exactly one single-cycle `clk_dst_i` pulse for each `clk_src_i` pulse, provided PERF-003 is met. |
| FUNC-005 | `cdckit_hs` MUST deliver at the destination the exact word accepted at the source, with no intermediate values or mixed bits. |
| FUNC-006 | `cdckit_hs` MUST NOT accept a new word (`src_ready_o = 0`) until all four phases of the previous transfer have completed. |
| FUNC-007 | `cdckit_afifo` MUST deliver words in the same order in which they were written, with no loss or duplication. |
| FUNC-008 | `cdckit_afifo` MUST NOT write to memory when `full_o = 1`, nor advance the read pointer when `empty_o = 1`. Such attempts are flagged on `wr_overflow_o` / `rd_underflow_o`. |
| FUNC-009 | `full_o` and `empty_o` MUST be conservative: they may assert earlier or deassert later than the real state, but they must NEVER allow overflow or underflow. |
| FUNC-010 | `rd_data_o` MUST present the word at the head of the FIFO while `empty_o = 0` (FWFT). |
| FUNC-011 | With `OUTPUT_ZERO_IF_EMPTY = 1`, `rd_data_o` MUST be zero while `empty_o = 1`. |
| FUNC-012 | After reset, the FIFO MUST present `empty_o = 1`, `full_o = 0`, `wr_level_o = 0` and `rd_level_o = 0`. |

### 3.4 Theory of operation

**Level synchronization.** A signal sampled asynchronously can drive the first flip-flop into a metastable state. The following stages provide resolution time before the value reaches functional logic. The failure probability decreases exponentially with that time (Annex A).

**Pulses.** A source pulse may be shorter than the destination period. It is therefore converted into a level transition (toggle), the level is synchronized, and the pulse is rebuilt at the destination by edge detection.

**Sporadic words.** The word is frozen in a holding register in the source domain. Only the `req` / `ack` control signals are synchronized. The protocol guarantees that the data is stable whenever the destination samples it.

**Continuous streams.** Data is written into a memory with the write clock and read with the read clock. Only the pointers cross, Gray-encoded: a single bit changes between consecutive values, so a capture during the transition returns either the old or the new value, never an invalid one. The synchronization delay makes each domain see the remote pointer late, so the flags are conservative.

---

## 4. Hardware interfaces

Table columns: **Dir** = direction, **Dom.** = clock domain, **Reset** = value during reset.

### 4.1 `cdckit_sync`

| Signal | Dir | Width | Dom. | Reset | Description |
|---|---|---|---|---|---|
| `clk_i` | in | 1 | — | — | Destination clock. |
| `rst_ni` | in | 1 | `clk_i` | — | Active-low asynchronous reset, already synchronized to the destination domain. |
| `d_i` | in | `WIDTH` | async | — | Input to synchronize. MUST come from a flip-flop. |
| `q_o` | out | `WIDTH` | `clk_i` | `RESET_VAL` | Synchronized output. |

### 4.2 `cdckit_rst_sync`

| Signal | Dir | Width | Dom. | Reset | Description |
|---|---|---|---|---|---|
| `clk_i` | in | 1 | — | — | Clock of the domain receiving the reset. |
| `arst_ni` | in | 1 | async | — | Asynchronous reset source (POR, link-down, software). |
| `rst_no` | out | 1 | `clk_i` | 0 | Domain reset: asynchronous assertion, synchronous deassertion. |

### 4.3 `cdckit_pulse_sync`

| Signal | Dir | Width | Dom. | Reset | Description |
|---|---|---|---|---|---|
| `clk_src_i` | in | 1 | — | — | Source clock. |
| `rst_src_ni` | in | 1 | `clk_src_i` | — | Source domain reset. |
| `pulse_src_i` | in | 1 | `clk_src_i` | — | Single-cycle event. |
| `clk_dst_i` | in | 1 | — | — | Destination clock. |
| `rst_dst_ni` | in | 1 | `clk_dst_i` | — | Destination domain reset. |
| `pulse_dst_o` | out | 1 | `clk_dst_i` | 0 | Single-cycle pulse for each source event. |

### 4.4 `cdckit_hs`

| Signal | Dir | Width | Dom. | Reset | Description |
|---|---|---|---|---|---|
| `clk_src_i` | in | 1 | — | — | Source clock. |
| `rst_src_ni` | in | 1 | `clk_src_i` | — | Source domain reset. |
| `src_valid_i` | in | 1 | `clk_src_i` | — | Word available. |
| `src_ready_o` | out | 1 | `clk_src_i` | 1 | The IP can accept a word. Registered output. |
| `src_data_i` | in | `DATA_W` | `clk_src_i` | — | Word to transfer. Captured in the `src_valid_i && src_ready_o` cycle. |
| `clk_dst_i` | in | 1 | — | — | Destination clock. |
| `rst_dst_ni` | in | 1 | `clk_dst_i` | — | Destination domain reset. |
| `dst_valid_o` | out | 1 | `clk_dst_i` | 0 | Single-cycle pulse: `dst_data_o` holds a new word. |
| `dst_data_o` | out | `DATA_W` | `clk_dst_i` | 0 | Last word received. Stable until the next transfer. |

Source-side protocol: AMBA **valid/ready**. `src_valid_i` MUST NOT depend on `src_ready_o`. The transfer occurs on the edge where both are 1. The destination side has no backpressure: the consumer MUST accept `dst_valid_o` in the cycle in which it asserts.

### 4.5 `cdckit_afifo`

**Write port (`wclk_i` domain)**

| Signal | Dir | Width | Reset | Description |
|---|---|---|---|---|
| `wclk_i` | in | 1 | — | Write clock. |
| `wrst_ni` | in | 1 | — | Write domain reset (see RST-004). |
| `wr_en_i` | in | 1 | — | Write request. Ignored if `full_o = 1`. |
| `wr_data_i` | in | `DATA_W` | — | Data to write. |
| `full_o` | out | 1 | 0 | FIFO full (conservative). Registered. |
| `almost_full_o` | out | 1 | 0 | `wr_level ≥ AF_THRESH`. Registered. |
| `wr_level_o` | out | `AW+1` | 0 | Occupancy seen from the write domain (≥ real occupancy). |
| `wr_overflow_o` | out | 1 | 0 | Pulse: `wr_en_i` occurred with `full_o = 1`. Registered. |

**Read port (`rclk_i` domain)**

| Signal | Dir | Width | Reset | Description |
|---|---|---|---|---|
| `rclk_i` | in | 1 | — | Read clock. |
| `rrst_ni` | in | 1 | — | Read domain reset (see RST-004). |
| `rd_en_i` | in | 1 | — | Consumes the head word. Ignored if `empty_o = 1`. |
| `rd_data_o` | out | `DATA_W` | — / 0 | Head word (FWFT). Zero if `OUTPUT_ZERO_IF_EMPTY = 1` and `empty_o = 1`. |
| `empty_o` | out | 1 | 1 | FIFO empty (conservative). Registered. |
| `almost_empty_o` | out | 1 | 1 | `rd_level ≤ AE_THRESH`. Registered. |
| `rd_level_o` | out | `AW+1` | 0 | Occupancy seen from the read domain (≤ real occupancy). |
| `rd_underflow_o` | out | 1 | 0 | Pulse: `rd_en_i` occurred with `empty_o = 1`. Registered. |

`AW = $clog2(DEPTH)`.

### 4.6 Interface requirements

| ID | Requirement |
|---|---|
| INTF-001 | All flag and status outputs of `cdckit_afifo` MUST be registered (no combinational path from an input). |
| INTF-002 | `src_ready_o` of `cdckit_hs` MUST be registered and MUST NOT depend combinationally on `src_valid_i`. |
| INTF-003 | Each signal MUST be used only in the domain indicated in its table. Using `wr_level_o` in `rclk_i` is an unsynchronized crossing. |
| INTF-004 | The integrating module MUST guarantee that `d_i` of `cdckit_sync` comes directly from a flip-flop in the source domain. |

### 4.7 Timing diagrams

**Write into an empty FIFO and first read** (`NUM_STAGES = 2`, `rclk` faster than `wclk`)

![Write into empty FIFO and first read](img/fig03_afifo_write_to_read.png)
*Figure 3 — Write→read latency: `NUM_STAGES+1` to `NUM_STAGES+2` `rclk` edges after the `wclk` edge that accepts the write.*

**Transfer through `cdckit_hs`**

![4-phase handshake waveform](img/fig04_hs_handshake.png)
*Figure 4 — 4-phase handshake.*

---

## 5. Configuration parameters

| Module | Parameter | Type | Range | Default | Description |
|---|---|---|---|---|---|
| all | `NUM_STAGES` | int | 2–4 | 2 | Synchronization stages. Chosen with the MTBF analysis (Annex A). |
| `cdckit_sync` | `WIDTH` | int | ≥ 1 | 1 | Number of independent bits. |
| `cdckit_sync` | `RESET_VAL` | logic [WIDTH-1:0] | — | `'0` | Output value during reset. |
| `cdckit_hs` | `DATA_W` | int | ≥ 1 | 32 | Word width. |
| `cdckit_afifo` | `DATA_W` | int | ≥ 1 | 72 | Word width. |
| `cdckit_afifo` | `DEPTH` | int | power of 2, ≥ 4 | 32 | Number of entries. |
| `cdckit_afifo` | `AF_THRESH` | int | 1 … `DEPTH` | `DEPTH-4` (`DEPTH-1` if `DEPTH = 4`) | `almost_full_o` threshold (≥). |
| `cdckit_afifo` | `AE_THRESH` | int | 0 … `DEPTH-1` | 2 | `almost_empty_o` threshold (≤). |
| `cdckit_afifo` | `OUTPUT_ZERO_IF_EMPTY` | bit | 0 / 1 | 0 | Forces `rd_data_o = 0` while the FIFO is empty. |

| ID | Requirement |
|---|---|
| PARAM-001 | The IP MUST stop elaboration (elaboration-time `$fatal` inside a `generate` block) if `DEPTH` is not a power of 2 or is less than 4, both in `xelab` and in `synth_design` (OI-10). |
| PARAM-002 | The IP MUST stop elaboration if `NUM_STAGES` is outside 2–4. |
| PARAM-003 | The IP MUST stop elaboration if `AF_THRESH` or `AE_THRESH` are out of range. |

**Rationale.**

- `DEPTH ≥ 4`: the `full` comparison inverts the two most significant bits of the Gray pointer and requires `AW ≥ 2`.
- `DEPTH` power of 2: the Gray sequence MUST close the cycle with a single-bit change.
- `OUTPUT_ZERO_IF_EMPTY = 0` by default: the masking adds `DATA_W` AND gates to the read path. Enabling it is recommended when `rd_data_o` drives logic not qualified by `empty_o`; this prevents `report_cdc` from reporting an unqualified data path in the consumer.

---

## 6. Clocks and resets

### 6.1 Clocks

| ID | Requirement |
|---|---|
| CLK-001 | The clocks of each primitive MAY have no frequency or phase relationship at all. |
| CLK-002 | The IP MUST operate correctly with any `f_src / f_dst` ratio within [1/16, 16]. Outside that range functionality is preserved but not verified in version 1.0. |
| CLK-003 | The IP MUST NOT generate, divide or gate clocks. |
| CLK-004 | If two domains share a nominal frequency with different sources (e.g. ±100 ppm), the IP MUST operate without loss. Rate compensation (idle insertion or removal) is the responsibility of the system. |

### 6.2 Resets

| ID | Requirement |
|---|---|
| RST-001 | All control flip-flops MUST use an active-low asynchronous reset, released synchronously in their domain through `cdckit_rst_sync`. On Artix-7 they map to `FDCE`/`FDPE`; the asynchronous reset is kept because FUNC-003 requires assertion without a clock, and for ASIC portability. |
| RST-002 | Data flip-flops (FIFO memory, `cdckit_hs` holding register) MAY have no reset. Their contents are never observed without a reset validity flag. |
| RST-003 | Each clock domain MUST receive its own `cdckit_rst_sync` instance. |
| RST-004 | For `cdckit_afifo`, `wrst_ni` and `rrst_ni` MUST be asserted with a time overlap of at least `NUM_STAGES+1` cycles of the slower clock, and the FIFO MUST be considered empty after release. |
| RST-005 | For `cdckit_hs`, a single-domain reset MAY lose the transfer in progress, but MUST NOT generate a spurious `dst_valid_o`. |
| RST-006 | For `cdckit_pulse_sync`, a destination-only reset MAY lose in-flight events, but MUST NOT generate a spurious `pulse_dst_o`. A source-only reset MAY generate at most one spurious `pulse_dst_o` (see OI-07). |

### 6.3 FIFO reset sequence

![FIFO reset sequence](img/fig05_afifo_reset_sequence.png)
*Figure 5 — Supported reset sequence.*

**Limitation.** Resetting a single FIFO domain while the other is active leaves the pointers inconsistent between domains: this is a Reset Domain Crossing not supported in version 1.0. The integrator MUST apply the sequence in Figure 5. See OI-02.

---

## 7. Performance and latency

### 7.1 Performance requirements

| ID | Requirement |
|---|---|
| PERF-001 | `cdckit_afifo` MUST accept one write per `wclk_i` cycle while `full_o = 0` and deliver one read per `rclk_i` cycle while `empty_o = 0`. |
| PERF-002 | With `NUM_STAGES = 2`, equal clocks and continuous traffic, `cdckit_afifo` SHOULD sustain 1 word/cycle without asserting `full_o` if `DEPTH ≥ 8`. Value to be confirmed in verification (OI-03). |
| PERF-003 | `cdckit_pulse_sync` guarantees delivery of every event if the spacing between two consecutive source pulses is ≥ `3·T_dst + 2·T_src`. With smaller spacing, consecutive pulses MAY merge into one. |
| PERF-004 | `cdckit_hs` MUST complete a transfer, from `src_valid_i && src_ready_o` to the new `src_ready_o = 1`, in ≤ `T_hs = 2·(NUM_STAGES+1)·(T_src + T_dst) + 2·T_src`. |
| PERF-005 | On the reference platform (§1.3), the implementation harness (§16.4) SHOULD close timing after `route_design` with `wclk` = 156.25 MHz and `rclk` = 250 MHz: WNS ≥ 0, WHS ≥ 0, TPWS ≥ 0 and `report_bus_skew` without violations. If `rclk` = 250 MHz does not close in speed grade -1, the requirement is evaluated at the Fmax obtained per PERF-006 (OI-13). |
| PERF-006 | The Fmax of each domain SHOULD be documented, obtained by reducing its clock period in 0.1 ns steps until WNS < 0. |
| PERF-007 | The resources and Fmax of each primitive versus its equivalent XPM macro (Table 8-1), implemented in the same harness, SHOULD be documented. |

### 7.2 Latency table (`NUM_STAGES = N`)

| Path | Minimum latency | Maximum latency | Time reference |
|---|---|---|---|
| `cdckit_sync`: `d_i` → `q_o` | N·T_dst | (N+1)·T_dst | Change of `d_i` |
| `cdckit_rst_sync`: assertion | 0 (asynchronous, combinational) | t_clr→q | Falling edge of `arst_ni` |
| `cdckit_rst_sync`: release | N `clk_i` edges | N+1 edges | Rising edge of `arst_ni` |
| `cdckit_pulse_sync`: event → `pulse_dst_o` | (N+1) `clk_dst` edges | (N+2) edges | `clk_src` edge that samples the pulse |
| `cdckit_hs`: acceptance → `dst_valid_o` | (N+1) `clk_dst` edges | (N+2) edges | `clk_src` acceptance edge |
| `cdckit_afifo`: write → `empty_o = 0` | (N+1) `rclk` edges | (N+2) edges | `wclk` edge that accepts the write |
| `cdckit_afifo`: read → `full_o = 0` | (N+1) `wclk` edges | (N+2) edges | `rclk` edge that accepts the read |
| `cdckit_afifo`: `rd_en_i` → next `rd_data_o` | 1 `rclk` edge | 1 edge | — |

The extra edge in the maximum covers two effects: sampling uncertainty (arbitrary phase between clocks) and the possibility that the first stage resolves metastability toward the previous value.

### 7.3 Depth sizing

For a burst of `B` words written at `f_w` while reading continuously at `f_r < f_w`, with no backpressure on the writer:

```
DEPTH ≥ B · (1 − f_r / f_w) + (N + 2)            ; rounded up to the next power of 2
```

NetSwitch-4 example, TX side (the core writes at 250 MHz and the MAC reads at 156.25 MHz), 1518 B frame in 190 beats of 8 B:

```
DEPTH ≥ 190 · (1 − 156.25/250) + 4 = 190 · 0.375 + 4 = 75.25   →   DEPTH = 128
```

The RX side (write at 156.25 MHz, read at 250 MHz) only absorbs core stalls. Its depth is set by the maximum stall duration specified by the core: reference configuration `DEPTH = 32`.

---

## 8. Integration requirements

| ID | Requirement |
|---|---|
| INTG-001 | The integrator MUST NOT insert combinational logic between the source flip-flop and the `d_i` port of `cdckit_sync`. |
| INTG-002 | The integrator MUST NOT separately synchronize bits that are later recombined or interpreted together (reconvergence). Such information MUST cross through `cdckit_hs` or `cdckit_afifo`. |
| INTG-003 | The integrator MUST load the module-scoped XDC files of §16 (`read_xdc -unmanaged -ref`, `PROCESSING_ORDER LATE`), so that they apply to every instance. |
| INTG-004 | The integrator MUST run `report_cdc -details` on the integrated design and justify every remaining warning with `create_waiver`, referencing §15. |
| INTG-005 | The `cdckit_sync` primitive MAY be replaced by `xpm_cdc_array_single` (FPGA) or by a library synchronizer cell (ASIC). The replacement MUST preserve the number of stages. `xpm_cdc_array_single` has no reset: the loss of `RESET_VAL` MUST be evaluated for each use. |
| INTG-006 | The consumer of `rd_data_o` MUST qualify its use with `empty_o = 0`, or the instance MUST be configured with `OUTPUT_ZERO_IF_EMPTY = 1`. |
| INTG-008 | Global `set_clock_groups` or `set_false_path` MUST NOT be used between the clocks of an instance, because they would override the constraints of §16 (STA-001). |

| `cdckit` primitive | Equivalent XPM macro | Relevant differences |
|---|---|---|
| `cdckit_sync` | `xpm_cdc_single` / `xpm_cdc_array_single` | XPM has no reset; same configurable number of stages. |
| `cdckit_rst_sync` | `xpm_cdc_async_rst` | XPM. |
| `cdckit_pulse_sync` | `xpm_cdc_pulse` | `cdckit` adds the arm window (MAS-PLS-5). |
| `cdckit_hs` | `xpm_cdc_handshake` | `cdckit` exposes valid/ready on the source side. |
| `cdckit_afifo` | `xpm_fifo_async` | `cdckit` adds `overflow`/`underflow` flags, per-domain levels and `OUTPUT_ZERO_IF_EMPTY`. |

*Table 8-1 — Equivalences with Vivado XPM macros (reference for PERF-007).*

---

# PART II — MICRO-ARCHITECTURE SPECIFICATION

## 9. Module hierarchy

![Module hierarchy](img/fig06_module_hierarchy.png)
*Figure 6 — Module hierarchy and RTL files.*

RTL files (all `.sv`, plus the file list):

| File | Contents |
|---|---|
| `rtl/cdckit_pkg.sv` | `bin2gray`, `gray2bin` functions, types. |
| `rtl/cdckit_sync.sv` | Synchronization primitive. |
| `rtl/cdckit_rst_sync.sv` | Reset synchronizer. |
| `rtl/cdckit_pulse_sync.sv` | Pulse synchronizer. |
| `rtl/cdckit_hs.sv` | 4-phase handshake. |
| `rtl/cdckit_afifo_mem.sv` | FIFO memory. |
| `rtl/cdckit_afifo_wptr.sv` | Write pointer logic. |
| `rtl/cdckit_afifo_rptr.sv` | Read pointer logic. |
| `rtl/cdckit_afifo.sv` | FIFO top. |
| `rtl/cdckit_sva.sv` | SVA checkers attached with `bind` (simulation only). |
| `rtl/cdckit_rtl.f` | Synthesizable RTL file list (`cdckit_sva.sv` is added in simulation only). |

The deliverables of the RTL phase are `.sv` files only. The implementation harness (`impl/cdckit_impl_top.sv`), the XDC files (`constraints/*.xdc`) and the Vivado script (`scripts/vivado_impl.tcl`) are referenced in §16 as targets of later phases. The `covergroup`s and the verification environment belong to phases 3 and 4.

---

## 10. `cdckit_sync` — Level synchronizer

### 10.1 Structure

![cdckit_sync structure](img/fig07_cdckit_sync.png)
*Figure 7 — Structure of `cdckit_sync`.*

### 10.2 Micro-architecture decisions

| ID | Decision | Rationale |
|---|---|---|
| MAS-SYNC-1 | Register vector `logic [NUM_STAGES-1:0][WIDTH-1:0] s_q` with attributes `(* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE" *)`. | In Vivado, `ASYNC_REG` prevents SRL packing and retiming, and places the stages in the same slice to maximize `t_r`; it is the mark by which `report_cdc` recognizes the synchronizer. `DONT_TOUCH` prevents replication and merging. |
| MAS-SYNC-2 | No gates between stages. | Maximizes the resolution time `t_r`. |
| MAS-SYNC-3 | Asynchronous reset to `RESET_VAL`. | Known state from the first clock cycle. |
| MAS-SYNC-4 | Implementation isolated in its own module. | Single point of replacement (`xpm_cdc_array_single` or library cell, INTG-005) and of recognition by `report_cdc`. |

### 10.3 Resources

`NUM_STAGES × WIDTH` flip-flops (`FDCE`); 0 LUT.

---

## 11. `cdckit_rst_sync` — Reset synchronizer

### 11.1 Structure

![cdckit_rst_sync structure](img/fig08_cdckit_rst_sync.png)
*Figure 8 — Structure of `cdckit_rst_sync`.*

### 11.2 Micro-architecture decisions

| ID | Decision | Rationale |
|---|---|---|
| MAS-RST-1 | `arst_ni` connected directly to the CLR input of every stage. | Immediate assertion, even with no active clock (FUNC-003). |
| MAS-RST-2 | The stages propagate a constant `1'b1`. | The release is aligned to `clk_i` after `NUM_STAGES` edges. |
| MAS-RST-3 | Reference equivalent: `xpm_cdc_async_rst`. | Its `report_cdc` classification and its resources are compared (PERF-007). |

---

## 12. `cdckit_pulse_sync` — Pulse synchronizer (toggle)

### 12.1 Structure

![cdckit_pulse_sync structure](img/fig09_cdckit_pulse_sync.png)
*Figure 9 — Structure of `cdckit_pulse_sync` with arm window.*

### 12.2 Logic

| Domain | Equation |
|---|---|
| Source | `tgl_q <= tgl_q ^ pulse_src_i;` |
| Destination | `arm_q <= {arm_q[N:0], 1'b1};`  `tgl_d <= tgl_s;`  `pulse_dst_q <= arm_q[N+1] & (tgl_s ^ tgl_d);` |
| Output | `pulse_dst_o = pulse_dst_q;` (registered; INTF-001 applied for consistency) |

### 12.3 Micro-architecture decisions

| ID | Decision | Rationale |
|---|---|---|
| MAS-PLS-1 | A level (`tgl_q`) crosses, never the pulse. | A pulse shorter than `T_dst` might not be sampled. |
| MAS-PLS-2 | `tgl_q` is a flip-flop. | No combinational logic drives the synchronizer (INTG-001). |
| MAS-PLS-3 | Registered output. | Glitch-free, at the cost of one edge of latency (§7.2). |
| MAS-PLS-4 | No acknowledge channel. | Minimum cost. The spacing constraint (PERF-003) is guaranteed by the integrator and checked by an `assume` assertion at the interface. |
| MAS-PLS-5 | Arm window of `NUM_STAGES+2` cycles after destination reset (`arm_q`). | After a destination-only reset, the synchronizer starts at 0 and converges to the current value of `tgl_q`, which the detector would see as an edge. The window covers the worst-case convergence: N stages, 1 edge for metastability and 1 for `tgl_d` (RST-006). |

---

## 13. `cdckit_hs` — Multibit transfer via 4-phase handshake

### 13.1 Structure

![cdckit_hs structure](img/fig10_cdckit_hs.png)
*Figure 10 — Structure of `cdckit_hs` and crossings CDC-X04 to CDC-X06.*

### 13.2 Source-domain FSM

| State | `src_ready_o` | `req_q` | Transition |
|---|---|---|---|
| `S_IDLE` | 1 | 0 | `src_valid_i` → `S_REQ`; also `hold_q <= src_data_i` |
| `S_REQ` | 0 | 1 | `ack_s == 1` → `S_DROP` |
| `S_DROP` | 0 | 0 | `ack_s == 0` → `S_IDLE` |

![cdckit_hs source-domain FSM](img/fig11_cdckit_hs_fsm.png)
*Figure 11 — Source-domain FSM of `cdckit_hs`.*

**Encoding:** 3-bit one-hot, held in `current_state` (next value `nxt_state`). `src_ready_o` and `req_q` are taken directly from a state bit (registered Moore outputs, no decoding). `default` returns to `S_IDLE`. The statement is `case`, not `unique case`: with `unique`, synthesis may assume illegal states never occur and remove the recovery logic. The written encoding is preserved with `FSM_ENCODING = "none"` (MAS-HS-6).

### 13.3 Destination-domain logic

| Signal | Equation |
|---|---|
| `ack_q` | `ack_q <= req_s;` |
| `dst_valid_q` | `dst_valid_q <= req_s & ~ack_q;` |
| `dst_data_q` | `if (req_s & ~ack_q) dst_data_q <= hold_q;` |

### 13.4 Micro-architecture decisions

| ID | Decision | Rationale |
|---|---|---|
| MAS-HS-1 | Holding register at the source. | Decouples `src_data_i` from the protocol: the sender may change its data after acceptance without affecting the transfer in progress. |
| MAS-HS-2 | `hold_q` is loaded only in `S_IDLE`. | Guarantees stability during phases 1–3, when the destination may sample. |
| MAS-HS-3 | The destination captures on the rising edge of `req_s` (`req_s & ~ack_q`). | A single capture per transfer; `dst_valid_o` lasts exactly one destination cycle. |
| MAS-HS-4 | `ack_q` is a delayed copy of `req_s`. | No FSM at the destination; minimal logic. |
| MAS-HS-5 | Registered destination outputs. | `dst_valid_o` and `dst_data_o` change on the same edge. |
| MAS-HS-6 | `current_state` MUST carry `(* FSM_ENCODING = "none" *)`. | `req_q` crosses domains directly from a state bit. If Vivado extracted and re-encoded the FSM, `req_q` would become combinational logic in front of the synchronizer, which is exactly what INTG-001 forbids and what `report_cdc` classifies as critical. |

---

## 14. `cdckit_afifo` — Asynchronous FIFO

### 14.1 Block diagram

![cdckit_afifo micro-architecture](img/fig12_cdckit_afifo.png)
*Figure 12 — Micro-architecture of `cdckit_afifo`.*

### 14.2 Write pointer logic (`cdckit_afifo_wptr`)

| Signal | Equation | Type |
|---|---|---|
| `w_push` | `wr_en_i & ~full_q` | comb |
| `wbin_d` | `wbin_q + w_push` | comb |
| `wgray_d` | `bin2gray(wbin_d) = (wbin_d >> 1) ^ wbin_d` | comb |
| `wq2_rbin` | `gray2bin(wq2_rgray)` | comb |
| `wlevel_d` | `wbin_d − wq2_rbin` (modulo 2^(AW+1)) | comb |
| `full_q` | `wgray_d == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]}` | reg |
| `almost_full_q` | `wlevel_d >= AF_THRESH` | reg |
| `wr_level_q` | `wlevel_d` | reg |
| `wr_overflow_q` | `wr_en_i & full_q` | reg |
| `wbin_q`, `wgray_q` | `wbin_d`, `wgray_d` | reg |
| `mem_we` | `w_push` | comb → `cdckit_afifo_mem` |

### 14.3 Read pointer logic (`cdckit_afifo_rptr`)

| Signal | Equation | Type |
|---|---|---|
| `r_pop` | `rd_en_i & ~empty_q` | comb |
| `rbin_d` | `rbin_q + r_pop` | comb |
| `rgray_d` | `bin2gray(rbin_d)` | comb |
| `rq2_wbin` | `gray2bin(rq2_wgray)` | comb |
| `rlevel_d` | `rq2_wbin − rbin_d` | comb |
| `empty_q` | `rgray_d == rq2_wgray` | reg (reset = 1) |
| `almost_empty_q` | `rlevel_d <= AE_THRESH` | reg (reset = 1) |
| `rd_level_q` | `rlevel_d` | reg |
| `rd_underflow_q` | `rd_en_i & empty_q` | reg |
| `rbin_q`, `rgray_q` | `rbin_d`, `rgray_d` | reg |

### 14.4 Memory (`cdckit_afifo_mem`)

| Aspect | Specification |
|---|---|
| Implementation | Dual-port distributed RAM (LUTRAM), inferred by Vivado from the `mem_q` array without reset. The asynchronous read prevents Block RAM inference. IMPL-003 requires checking in `report_utilization` that LUTRAM, not registers, is inferred. |
| Write | Synchronous to `wclk_i`, enabled by `mem_we`, address `wbin_q[AW-1:0]`. |
| Read | Asynchronous from the LUTRAM read port, address `rbin_q[AW-1:0]` (FWFT). With `DEPTH = 32`, one LUT level. |
| Output | `rd_data_o = (OUTPUT_ZERO_IF_EMPTY && empty_q) ? '0 : mem[rbin_q[AW-1:0]]`. |
| Enable | `mem_we` acts as the LUTRAM WE. No ICGs are inferred on FPGA (§18.2). |

### 14.5 Micro-architecture decisions

| ID | Decision | Rationale |
|---|---|---|
| MAS-AF-1 | `AW+1`-bit pointers. | The extra bit distinguishes full from empty without sacrificing an entry. |
| MAS-AF-2 | The **registered** Gray pointers (`wgray_q`, `rgray_q`) are synchronized, never `wgray_d`. | The combinational output of `bin2gray` can glitch and change more than one bit during evaluation. |
| MAS-AF-3 | Two representations coexist per domain (binary for addressing, Gray for crossing). | Avoids a Gray→binary conversion in the memory address path. |
| MAS-AF-4 | `full` and `empty` are computed from the *next* pointers (`*_d`) and registered. | The flags reflect the current cycle's operation without an extra cycle of delay, and remain registered (INTF-001). |
| MAS-AF-5 | `full` compares the two MSBs inverted. | In reflected Gray code, the equivalent of "MSB different and the rest equal" in binary. |
| MAS-AF-6 | Levels are computed from the synchronized remote pointer. | `wr_level_o` is an upper bound and `rd_level_o` a lower bound of the real occupancy. Both are safe for flow control. |
| MAS-AF-7 | Memory inferred as LUTRAM with asynchronous read. | FWFT with no extra latency cycle. The reference configuration goes from ≈ 2370 to ≈ 66 flip-flops (§18.1). For large `DEPTH × DATA_W`, Block RAM with prefetch is planned (OI-01). |
| MAS-AF-8 | Combinational `gray2bin`. | XOR chain of depth AW. If it limits timing, `wq2_rbin` / `rq2_wbin` are registered at the cost of one extra cycle of pessimism in the levels (OI-05). |
| MAS-AF-9 | `wgray_q` and `rgray_q` MUST carry `(* DONT_TOUCH = "TRUE" *)`. | The MSB of the Gray pointer is identical to the binary MSB. Vivado would therefore merge `wgray_q[AW]` with `wbin_q[AW]` (equivalent register removal). The crossing's launch flop would be renamed, would no longer be covered by the constraints of §16, and would drive logic in its own domain in addition to the synchronizer. |

### 14.6 Expected critical paths

| ID | Path | Domain | Approximate logic depth | Mitigation |
|---|---|---|---|---|
| CP-1 | `wbin_q` → +1 → `bin2gray` → `AW+1` comparator → `full_q` | `wclk` | `AW+1` adder + XOR + comparison tree | Precompute `wbin_q + 1` in a register. |
| CP-2 | `wq2_rgray` → `gray2bin` → subtraction → compare with `AF_THRESH` → `almost_full_q` | `wclk` | AW XOR chain + `AW+1` subtraction + comparator | MAS-AF-8 (register `wq2_rbin`). |
| CP-3 | `rbin_q` → LUTRAM address → `rd_data_o` | `rclk` | 1 LUT (`DEPTH ≤ 32`) + `OUTPUT_ZERO_IF_EMPTY` mask | Output register in the consumer; Block RAM with prefetch (OI-01). |
| CP-4 | CDC path LUTRAM → consumer register | `wclk` → `rclk` | — | Qualified path; constrained with `set_max_delay -datapath_only` (§16). |

CP-1 and CP-2 in `rclk` (4.0 ns) are the candidates to limit Fmax on Artix-7 speed grade -1 (OI-13).

---

## 15. CDC intent and crossing table

### 15.1 Crossing table

| ID | Module | Source signal | Source → destination domain | Width | Scheme | Synchronization structure | Qualifier |
|---|---|---|---|---|---|---|---|
| CDC-X01 | `cdckit_sync` | `d_i` | async → `clk_i` | `WIDTH` | Level, independent bits | `NUM_STAGES` flops | — |
| CDC-X02 | `cdckit_rst_sync` | `arst_ni` (release) | async → `clk_i` | 1 | Reset async-assert / sync-deassert | `NUM_STAGES` flops with CLR | — |
| CDC-X03 | `cdckit_pulse_sync` | `tgl_q` | `clk_src` → `clk_dst` | 1 | Toggle | `cdckit_sync` | — |
| CDC-X04 | `cdckit_hs` | `req_q` | `clk_src` → `clk_dst` | 1 | 4-phase handshake | `cdckit_sync` | — |
| CDC-X05 | `cdckit_hs` | `ack_q` | `clk_dst` → `clk_src` | 1 | 4-phase handshake | `cdckit_sync` | — |
| CDC-X06 | `cdckit_hs` | `hold_q` | `clk_src` → `clk_dst` | `DATA_W` | Bundled data | None (stable data) | `req_s & ~ack_q` |
| CDC-X07 | `cdckit_afifo` | `wgray_q` | `wclk` → `rclk` | `AW+1` | Gray | `cdckit_sync` (`u_sync_w2r`) | — |
| CDC-X08 | `cdckit_afifo` | `rgray_q` | `rclk` → `wclk` | `AW+1` | Gray | `cdckit_sync` (`u_sync_r2w`) | — |
| CDC-X09 | `cdckit_afifo` | `mem[*]` | `wclk` → `rclk` | `DATA_W` | FIFO (data in memory) | None | `empty_q == 0` |

### 15.2 CDC requirements

| ID | Requirement |
|---|---|
| CDC-001 | `report_cdc -details` on the harness (§16.4) MUST NOT contain *Critical* results. Every *Warning* result MUST be covered by a `create_waiver` with its justification and a reference to §15.3. |
| CDC-002 | No crossing MUST exhibit reconvergence of separately synchronized signals. |
| CDC-003 | Buses X07 and X08 MUST change at most one bit per cycle of their source clock (SVA-01, SVA-02), and their skew MUST be bounded by `set_bus_skew` (STA-004). |
| CDC-004 | There MUST be no unjustified reset domain crossings under the sequence of Figure 5. Vivado has no dedicated RDC analysis, so this is verified in three ways: simulation of the sequence (TP-AF-05), recognition of `cdckit_rst_sync` as a reset synchronizer in `report_cdc`, and design review. |

### 15.3 Expected `report_cdc` classification

| Crossing | Expected topology | Expected severity | Treatment |
|---|---|---|---|
| X01, X03, X04, X05 | 1-bit synchronizer with `ASYNC_REG` | Info (safe) | — |
| X02 | Asynchronous reset synchronizer with `ASYNC_REG` | Info (safe) | — |
| X07, X08 | Multibit synchronizer with `ASYNC_REG` (rule CDC-6) | Warning | Waiver: Gray encoding (SVA-01, SVA-02) and `set_bus_skew` (§16.2). It is the same waiver that `xpm_cdc_gray` applies. |
| X06 | Structure controlled by a *clock enable* (`dst_load`) | Warning | Waiver: bundled data, stable during `req` (SVA-09) and bounded with `set_max_delay`. |
| X09 | Path from LUTRAM written in `wclk` to the `rclk` domain | Warning | Waiver: the pointer protocol prevents reading a word while it is being written (FUNC-008, FUNC-009). |

The exact rule identifiers, except CDC-6, will be recorded from the first report and fixed in the implementation phase (OI-11).

---

## 16. Timing constraints (XDC)

This section specifies the **intent** of the constraints. The `.xdc` files, the harness and the Vivado script are written in the implementation phase (§9).

### 16.1 Principle

In Vivado, `set_clock_groups` and `set_false_path` take **precedence** over `set_max_delay`, and clock groups cannot be overridden. Therefore, if a path between two clocks is constrained with `set_max_delay -datapath_only`, those two clocks MUST NOT be grouped with `set_clock_groups`. `set_bus_skew`, in contrast, is not an exception but a timing assertion: it is always evaluated, it is optimized only by `route_design`, and it is reported by `report_bus_skew`, not in `report_timing_summary`.

The IP policy is to bound **all** of its internal crossings with `set_max_delay -datapath_only`, without `set_false_path`. This way every crossing has a guaranteed maximum latency and none is left unanalyzed.

### 16.2 Module-scoped files

Each file is loaded as **unmanaged** constraints scoped to the module (`read_xdc -unmanaged -ref <module>`) and with `PROCESSING_ORDER LATE`, just like the XPM macros. Full Tcl makes it possible to read the periods of the clocks reaching each instance, without fixed hierarchical paths, and to check STA-006 inside the file itself (`send_msg_id` with a *critical warning* if a cell query is empty).

```tcl
## constraints/cdckit_afifo.xdc  — SCOPED_TO_REF cdckit_afifo, PROCESSING_ORDER LATE
set t_w [get_property PERIOD [get_clocks -of_objects [get_pins {u_wptr/wgray_q_reg[0]/C}]]]
set t_r [get_property PERIOD [get_clocks -of_objects [get_pins {u_rptr/rgray_q_reg[0]/C}]]]

# CDC-X07: wgray_q -> u_sync_w2r (Gray)
set_max_delay -datapath_only -from [get_cells {u_wptr/wgray_q_reg[*]}] \
              -to [get_cells {u_sync_w2r/s_q_reg[0][*]}] $t_w
set_bus_skew  -from [get_cells {u_wptr/wgray_q_reg[*]}] \
              -to [get_cells {u_sync_w2r/s_q_reg[0][*]}] [expr {min($t_w, $t_r)}]

# CDC-X08: rgray_q -> u_sync_r2w (Gray)
set_max_delay -datapath_only -from [get_cells {u_rptr/rgray_q_reg[*]}] \
              -to [get_cells {u_sync_r2w/s_q_reg[0][*]}] $t_r
set_bus_skew  -from [get_cells {u_rptr/rgray_q_reg[*]}] \
              -to [get_cells {u_sync_r2w/s_q_reg[0][*]}] [expr {min($t_w, $t_r)}]

# CDC-X09: LUTRAM (written in wclk) -> read domain
set_max_delay -datapath_only -from [get_cells -hierarchical -filter {REF_NAME =~ RAM*}] \
              -to [get_clocks -of_objects [get_pins {u_rptr/rgray_q_reg[0]/C}]] $t_r
```

```tcl
## constraints/cdckit_hs.xdc  — SCOPED_TO_REF cdckit_hs, PROCESSING_ORDER LATE
set t_s [get_property PERIOD [get_clocks -of_objects [get_pins {hold_q_reg[0]/C}]]]
set t_d [get_property PERIOD [get_clocks -of_objects [get_pins {dst_data_q_reg[0]/C}]]]

# CDC-X04 / X05: req and ack (1 bit)
set_max_delay -datapath_only -from [get_cells {current_state_reg[1]}] \
              -to [get_cells {u_sync_req/s_q_reg[0][0]}] $t_d
set_max_delay -datapath_only -from [get_cells {ack_q_reg}] \
              -to [get_cells {u_sync_ack/s_q_reg[0][0]}] $t_s
# CDC-X06: bundled data
set_max_delay -datapath_only -from [get_cells {hold_q_reg[*]}] \
              -to [get_cells {dst_data_q_reg[*]}] $t_d
```

```tcl
## constraints/cdckit_pulse_sync.xdc  — SCOPED_TO_REF cdckit_pulse_sync, PROCESSING_ORDER LATE
set t_d [get_property PERIOD [get_clocks -of_objects [get_pins {tgl_d_q_reg/C}]]]
# CDC-X03: toggle (1 bit)
set_max_delay -datapath_only -from [get_cells {tgl_q_reg}] \
              -to [get_cells {u_sync/s_q_reg[0][0]}] $t_d
```

```tcl
## constraints/cdckit_impl_top.xdc  — implementation harness (§16.4)
create_clock -name wclk -period 6.400 [get_ports wclk_i]
create_clock -name rclk -period 4.000 [get_ports rclk_i]
# CDC-X02: only the assertion path of the asynchronous reset. The release is analyzed as
# recovery/removal at the output of cdckit_rst_sync.
set_false_path -from [get_ports arst_ni]
# No set_clock_groups between wclk and rclk (STA-001).
```

The cell names (`*_reg`, `s_q_reg[0][*]`) follow Vivado's naming for inferred registers. They MUST be checked after the first synthesis: a constraint with an empty `-from` or `-to` applies nothing, and Vivado only issues a warning.

### 16.3 Timing requirements

| ID | Requirement |
|---|---|
| STA-001 | `set_clock_groups` and `set_false_path` MUST NOT be used between the clocks of an instance. Every internal crossing MUST be bounded with `set_max_delay -datapath_only` (§16.1). |
| STA-002 | The stages of `cdckit_sync` MUST carry `ASYNC_REG` and `DONT_TOUCH`; they MUST NOT appear packed into SRLs, retimed or replicated. |
| STA-003 | The recovery/removal checks from the output of `cdckit_rst_sync` to the domain flops MUST be met (`report_timing_summary`). |
| STA-004 | `report_bus_skew` MUST NOT report violations on X07 and X08. |
| STA-005 | `report_timing_summary -check_timing` MUST NOT report unconstrained paths or missing clocks inside the IP. `report_methodology` MUST NOT report unjustified TIMING-* warnings. |
| STA-006 | Every constraint in §16.2 MUST resolve at least one cell in `-from` and in `-to` (checked after synthesis). |

### 16.4 Implementation harness

| ID | Requirement |
|---|---|
| IMPL-001 | The implementation harness (`impl/cdckit_impl_top.sv`, implementation phase) MUST instantiate each primitive at least once (`cdckit_afifo` `wclk`→`rclk`, `cdckit_hs`, `cdckit_pulse_sync`, `cdckit_sync` and one `cdckit_rst_sync` per domain) with the reference configuration. |
| IMPL-002 | All harness inputs and outputs MUST be registered in their domain, so that every analyzed path is register-to-register. `rd_data_o` is registered in `rclk`. Synthesis is *out-of-context*; the harness ports are not constrained. |
| IMPL-003 | `report_utilization` MUST show the `cdckit_afifo` memory as LUTRAM. The synthesis log MUST NOT contain inferred latches. |

---

## 17. Design assertions

The assertions are delivered in `rtl/cdckit_sva.sv`, attached with `bind` and run in xsim.

- Properties marked as *assume* are assumptions about the environment. Since the platform has no formal verification (OI-08), they run as `assert` and detect illegal testbench stimulus.
- xsim does not support `cover property`; functional coverage (`covergroup`) is defined in the verification plan (phase 3) and is not part of the RTL files.
- xsim does not support multiclock properties, so each property uses a single clock.

| ID | Module | Type | Property (summary) | Clock |
|---|---|---|---|---|
| SVA-01 | `cdckit_afifo` | assert | `$countones(wgray_q ^ $past(wgray_q)) <= 1` | `wclk` |
| SVA-02 | `cdckit_afifo` | assert | `$countones(rgray_q ^ $past(rgray_q)) <= 1` | `rclk` |
| SVA-03 | `cdckit_afifo` | assert | `full_q` and `wr_en_i` imply that `wbin_q` does not change (`$stable`) | `wclk` |
| SVA-04 | `cdckit_afifo` | assert | `empty_q` and `rd_en_i` imply that `rbin_q` does not change (`$stable`) | `rclk` |
| SVA-05 | `cdckit_afifo` | assert | `wr_level_q <= DEPTH` | `wclk` |
| SVA-06 | `cdckit_afifo` | assert | `rd_level_q <= DEPTH` | `rclk` |
| SVA-07 | `cdckit_afifo` | assert | `!$isunknown(full_q)` and `!$isunknown(empty_q)` outside reset | `wclk` / `rclk` |
| SVA-08 | `cdckit_hs` | assert | `$onehot(current_state)` | `clk_src` |
| SVA-09 | `cdckit_hs` | assert | `hold_q` stable (`$stable`) while `current_state != S_IDLE` | `clk_src` |
| SVA-10 | `cdckit_hs` | assert | `dst_valid_q |=> !dst_valid_q` (single-cycle pulse) | `clk_dst` |
| SVA-11 | `cdckit_hs` | assume | `src_valid_i && !src_ready_o |=> src_valid_i && $stable(src_data_i)` | `clk_src` |
| SVA-12 | `cdckit_pulse_sync` | assume | After `pulse_src_i`, no other pulse during the PERF-003 spacing | `clk_src` |
| SVA-13 | `cdckit_pulse_sync` | assert | `pulse_dst_q |=> !pulse_dst_q` | `clk_dst` |

All concurrent assertions use `disable iff (!rst_ni)` of their clock's domain. SVA-01 and SVA-02 are evaluated **exclusively** with the source clock of the bus.

---

## 18. Resources, power and ASIC portability

### 18.1 Resource estimate (Artix-7)

| Module | Flip-flops (formula) | FF (ref.) | LUT / LUTRAM (estimate) |
|---|---|---|---|
| `cdckit_sync` | `N·WIDTH` | `2·WIDTH` | 0 |
| `cdckit_rst_sync` | `N` | 2 | 0 |
| `cdckit_pulse_sync` | `1 + N + 1 + 1 + (N+2)` | 9 | ≈ 2 LUT |
| `cdckit_hs` | `3 + DATA_W + 2N + 1 + 1 + DATA_W` | 73 (`DATA_W = 32`) | ≈ 5 LUT + CE on 64 FF |
| `cdckit_afifo` | `2·[2(AW+1) + N(AW+1)] + 2(AW+1) + 6` | 66 | ≈ 48 LUT as LUTRAM (72 b ÷ 6 b per `RAM32M` → 12 × 4 LUT) + pointer logic |

On FPGA the FIFO memory consumes no flip-flops. If Vivado inferred registers, the total would rise to `DEPTH·DATA_W + 66` = 2370 FF; that is why IMPL-003 requires checking the inference. In 7 series, a `RAM32M` (4 LUTs, only in SLICEM slices) implements a 32×6 simple dual-port RAM. The LUT columns are estimates and will be replaced by `report_utilization` values (PERF-007).

### 18.2 Power

| ID | Measure |
|---|---|
| PWR-1 | No ICGs are inferred on FPGA. The write uses the LUTRAM WE and the enabled registers use the CE pin: no storage element toggles without a write. |
| PWR-2 | Gray-coded pointers toggle one bit per operation, which reduces synchronizer activity. |
| PWR-3 | *(Informative, ASIC.)* If the IP is instantiated at the boundary of a power-gated domain, the integrator MUST isolate the outputs of the powered-down domain; the recommended clamp values are `empty_o = 1`, `full_o = 1` and `*_valid_o = 0`. The reference FPGA has no power gating. |
| PWR-4 | Dynamic power SHOULD be estimated with `report_power` using SAIF activity from an xsim continuous-traffic simulation. |

### 18.3 ASIC portability: DFT (informative)

The reference FPGA does not support scan insertion. The following requirements are kept for a future ASIC implementation and are **outside the v1.0 verification scope**.

| ID | Requirement |
|---|---|
| DFT-001 | All flip-flops, including the synchronizer flops and the memory, MUST be scannable. |
| DFT-002 | `cdckit_rst_sync` does not include reset control for scan; in ASIC it MUST be added in the integration wrapper (test mux on `rst_no`, *don't touch* library cell). |
| DFT-003 | In scan capture mode, the `wclk` and `rclk` clocks MUST belong to different scan domains, or be captured with a scheme that avoids capture crossings between them. |
| DFT-004 | ICGs inferred in ASIC MUST have their test-enable pin connected to `scan_enable`. |

---

## 19. Requirements traceability matrix

Verification methods:

| Method | Meaning |
|---|---|
| **SIM** | Simulation in xsim with UVM 1.2 and SVA assertions. |
| **COV** | Functional coverage (defined in the verification plan) and code coverage (`xcrg`). |
| **LINT** | Vivado RTL Linter. |
| **SYN** | Synthesis: log, `report_utilization` and schematic. |
| **STA** | `report_timing_summary` and `report_bus_skew` after `route_design`. |
| **CDC** | `report_cdc -details` with justified waivers. |
| **METH** | `report_methodology`. |
| **MTBF** | Annex A calculation with device characterization data. |
| **REV** | Design review. |

The *Plan* column references the identifiers to be defined in phase 3 (verification plan).

| Requirement | Method | Evidence | Plan |
|---|---|---|---|
| FUNC-001, FUNC-002 | LINT, CDC | Every synchronizer classified by `report_cdc`; no combinational logic before a synchronizer | TP-CDC-01 |
| FUNC-003 | SIM | Assertion of the release after N edges; assertion of the reset without a clock | TP-RST-01 |
| FUNC-004 | SIM | Event-count scoreboard; SVA-13 | TP-PLS-01 |
| FUNC-005, FUNC-006 | SIM, COV | Word scoreboard; SVA-08, SVA-09; coverage of back-to-back transfers and FSM states (verification plan) | TP-HS-01 |
| FUNC-007 | SIM | Ordering scoreboard with random clocks | TP-AF-01 |
| FUNC-008 | SIM, COV | SVA-03, SVA-04; coverage of attempts with the FIFO full / empty (verification plan) | TP-AF-02 |
| FUNC-009 | SIM | Safety checker: model full ⇒ `full_o`, model empty ⇒ `empty_o` | TP-AF-03 |
| FUNC-010, FUNC-011 | SIM | Comparison of `rd_data_o` with the model head, for both parameter values | TP-AF-04 |
| FUNC-012, RST-004 | SIM | Figure 5 reset sequence at different occupancy levels | TP-AF-05 |
| RST-005, RST-006 | SIM | Single-domain reset with a transfer in flight; absence of spurious pulses (except the bounded RST-006 case) | TP-HS-02, TP-PLS-02 |
| CLK-002 | SIM, COV | Clock-ratio sweep, including phase drift with near-equal frequencies | TP-CLK-01 |
| PERF-001, PERF-002 | SIM | Sustained throughput measurement | TP-PERF-01 |
| PERF-003, PERF-004 | SIM | Spacing and cycle-time measurement | TP-PERF-02 |
| PERF-005, PERF-006 | STA | Timing reports after `route_design`; period sweep | TP-IMPL-01 |
| PERF-007 | SYN, STA | `cdckit` vs XPM comparison table | TP-IMPL-02 |
| STA-001…006 | STA, METH, REV | Timing, bus-skew and methodology reports; constraint-check script | TP-IMPL-01 |
| IMPL-001…003 | SYN, REV | Harness, `report_utilization`, synthesis log | TP-IMPL-01 |
| CDC-001, CDC-002 | CDC | `report_cdc` with no Critical; §15.3 waivers | TP-CDC-01 |
| CDC-003 | SIM, STA | SVA-01, SVA-02; `report_bus_skew` | TP-AF-06 |
| CDC-004 | SIM, CDC, REV | Reset sequence (TP-AF-05); `cdckit_rst_sync` recognized as a reset synchronizer | TP-AF-05 |
| MTBF-001, MTBF-002 | MTBF | Annex A calculation on the harness synchronizers | TP-IMPL-03 |
| PARAM-001…003 | SIM, SYN | Negative elaboration test in `xelab` and in `synth_design` | TP-PARAM-01 |
| INTF-001, INTF-002 | SYN, REV | Post-synthesis schematic: outputs from registers | — |
| PWR-4 | SIM, SYN | `report_power` with SAIF | TP-IMPL-04 (optional) |
| DFT-001…004, PWR-3 | — | Outside the v1.0 scope (ASIC) | — |

---

## 20. Open issues

| ID | Issue | Impact | Proposal | Status |
|---|---|---|---|---|
| OI-01 | Block RAM support (synchronous read) with prefetch to keep FWFT. | Resources for large `DEPTH·DATA_W`; read latency +1 without prefetch. | `MEM_STYLE` parameter in version 1.1. | Open |
| OI-02 | Independent per-domain reset in `cdckit_afifo`. | RDC; NetSwitch-4 requires resetting the port on link-down without resetting the core. | Reset protocol with a handshake between domains, or synchronized reset of both sides from the initiating domain. | Open |
| OI-03 | Minimum depth for sustained throughput with equal clocks. | PERF-002. | Confirm by performance simulation (TP-PERF-01). | Open |
| OI-04 | Target frequency and device. | PERF-005. | `xc7a100tcsg324-1` at 156.25 / 250 MHz (§1.3). | Closed (v0.7) |
| OI-05 | Optional `gray2bin` register in the level computation. | CP-2 timing vs `almost_*` pessimism. | Decide after the first synthesis. | Open |
| OI-06 | Acknowledge channel in `cdckit_pulse_sync` (`busy_o`). | Avoid event merging when spacing is not guaranteed. | `cdckit_pulse_sync_ack` variant in version 1.1. | Open |
| OI-07 | Spurious pulse in `cdckit_pulse_sync` on source-only reset. | If `tgl_q = 1` when the source is reset, its fall to 0 is seen as an event at the destination. | Require a joint reset at system level, or a variant with Gray-counter event encoding in v1.1. | Open |
| OI-08 | Formal verification outside the platform. | SVA-11 and SVA-12 only as `assert`; FUNC-003, FUNC-005 and FUNC-008 without exhaustive proof. | Compensate with random regression and coverage. Optional formal outside the platform in a future version. | Accepted |
| OI-09 | UVM 1.2 in xsim instead of IEEE 1800.2. | Minor API differences. | Do not use APIs removed in 1800.2, to ease migration. | Accepted |
| OI-10 | Behavior of `synth_design` on elaboration `$fatal`s. | PARAM-001…003 in synthesis. | Negative test in synthesis; if it does not stop the flow, add the check to the Tcl script. | Open |
| OI-11 | `report_cdc` rule identifiers for X06 and X09. | §15.3. | Fix them from the first report, in the implementation phase. | Open |
| OI-12 | RTL changes derived from v0.4. | MAS-HS-6 and MAS-AF-9 (synthesis attributes). | Applied in the RTL. Harness and XDC deferred to the implementation phase. | Closed (v0.7) |
| OI-13 | Timing closure of `rclk` = 250 MHz on Artix-7 speed grade -1. | PERF-005; CP-1 and CP-2 (§14.6). | Measure Fmax after `route_design`. If it does not close, apply MAS-AF-8 / CP-1 precomputation or reduce `rclk` and document the Fmax. | Open |

---

# ANNEXES

## Annex A — MTBF analysis

Vivado's `report_synchronizer_mtbf` command computes MTBF with device characterization data, but according to UG835 it applies to the UltraScale and UltraScale+ families. On Artix-7, MTBF is computed with the following analytical model, taking τ and T₀ from the metastability characterization that AMD publishes for the 7 series family. Synchronizers are identified by `ASYNC_REG`.

Synchronizer model:

```
MTBF = e^(t_r / τ) / (T_0 · f_clk · f_data)
t_r ≈ T_clk − t_clk→q − t_setup        (no logic between stages; per additional stage)
```

**Illustrative** example (τ and T₀ do not come from a real library): `wgray` bus into `rclk` in the reference configuration, with τ = 20 ps, T₀ = 50 ps, `f_clk = 250 MHz`, `f_data ≤ 156.25 MHz` and `t_r ≈ 3.9 ns`.

```
t_r / τ = 195          e^195 ≈ 10^84.7
denominator = 50e-12 · 250e6 · 156.25e6 ≈ 1.95e6 s⁻¹
MTBF per bit ≈ 10^78 s                  →  with AW+1 = 6 bits: ≈ 10^77 s
```

| ID | Requirement |
|---|---|
| MTBF-001 | The aggregate MTBF of all synchronizers in an instance MUST exceed 1000 times the target product lifetime, computed with the model in this annex, with `t_r` obtained from the stage slack after `route_design` and with τ and T₀ from AMD characterization. |
| MTBF-002 | If MTBF-001 is not met with `NUM_STAGES = 2`, `NUM_STAGES` MUST be increased. |
| MTBF-003 | The calculation MUST document the toggle rate assumed for the source signals. For the Gray pointers, the full-rate write or read rate SHOULD be used, which is the worst case. |

## Annex B — Reference integration: 64-bit counter snapshot

Informative composition (not part of the IP) that coherently reads a 64-bit counter in the `clk_rx` domain from the `clk_cfg` domain.

![64-bit counter snapshot](img/fig13_counter_snapshot.png)
*Figure 13 — Reference integration: coherent snapshot of a 64-bit counter.*

Software writes a control bit (`snap_req`), waits for `snap_valid` (or polls it in a status register) and reads the coherent 64-bit value. If `snap_req_rx` arrives with `src_ready_o = 0`, the request is ignored. The integrator MUST prevent requests at that rate, or hold them until `src_ready_o = 1`.

## Annex C — Glossary

| Term | Definition |
|---|---|
| CDC | *Clock Domain Crossing*: transfer of a signal between flip-flops whose clocks have no guaranteed phase relationship. |
| RDC | *Reset Domain Crossing*: path between flip-flops with different asynchronous resets. |
| FWFT | *First-Word Fall-Through*: the head word is available at the output without a prior read cycle. |
| Gray | Code in which two consecutive values differ in a single bit. |
| Metastability | Intermediate state of a bistable whose resolution to 0 or 1 takes an unbounded time. |
| MTBF | *Mean Time Between Failures* of a synchronizer. |
| Bundled data | Scheme in which a stable data bus accompanies a synchronized control signal. |
| Reconvergence | Combination of separately synchronized signals that may arrive in different cycles. |
| Recovery / removal | Timing checks on the release of an asynchronous reset relative to the clock edge. |
| XDC | *Xilinx Design Constraints*: Vivado constraint format, based on SDC. |
| XPM | *Xilinx Parameterized Macros*: Vivado macros for CDC (`xpm_cdc_*`), memories and FIFOs. |
| LUTRAM | Distributed RAM built from CLB LUTs; supports asynchronous read. |
| OOC | *Out-of-context*: synthesis of a module without I/O buffers, as an isolated block. |
| WNS / WHS / TPWS | *Worst Negative Slack* (setup), *Worst Hold Slack* and *Total Pulse Width Slack*. |
| Waiver | Recorded justification (`create_waiver`) that accepts a `report_cdc` or methodology result. |

## Annex D — References

1. IEEE Std 1800-2017, *SystemVerilog — Unified Hardware Design, Specification, and Verification Language*.
2. C. E. Cummings, *Simulation and Synthesis Techniques for Asynchronous FIFO Design*, SNUG San Jose, 2002.
3. C. E. Cummings, *Clock Domain Crossing (CDC) Design & Verification Techniques Using SystemVerilog*, SNUG Boston, 2008.
4. R. Ginosar, "Metastability and Synchronizers: A Tutorial", *IEEE Design & Test of Computers*, 2011.
5. AMD, *FIFO Generator LogiCORE IP Product Guide* (PG057), and *Embedded FIFO Generator LogiCORE IP Product Guide* (PG327): per-domain port structure, `overflow` / `underflow` flags, data counters.
6. lowRISC / OpenTitan, *Comportability Definition and Specification* and IP specification template (Overview, Features, Theory of Operation, Hardware Interfaces, Design Details); primitives `prim_flop_2sync`, `prim_pulse_sync`, `prim_fifo_async` (`OutputZeroIfEmpty` parameter).
7. IETF RFC 2119, *Key words for use in RFCs to Indicate Requirement Levels*.
8. AMD, *Vivado Design Suite User Guide: Logic Simulation* (UG900): SystemVerilog and SVA support in xsim, UVM, code coverage.
9. AMD, *Vivado Design Suite User Guide: Synthesis* (UG901): RTL Linter, `ASYNC_REG`, `DONT_TOUCH`, `FSM_ENCODING` attributes.
10. AMD, *Vivado Design Suite User Guide: Using Constraints* (UG903): exception precedence, `set_bus_skew`, `ASYNC_REG`.
11. AMD, *Vivado Design Suite User Guide: Design Analysis and Closure Techniques* (UG906): `report_cdc` and its rules.
12. AMD, *UltraFast Design Methodology Guide* (UG949): CDC constraints and precedence over `set_max_delay`.
13. AMD, *Vivado Design Suite Tcl Command Reference* (UG835): `report_cdc`, `create_waiver`, `report_synchronizer_mtbf`.
14. AMD, *UltraScale Architecture Libraries Guide* (UG974): `xpm_cdc_*` and `xpm_fifo_async` macros.
15. AMD, *Vivado Design Suite User Guide: Release Notes, Installation, and Licensing* (UG973): devices included in the free edition.
16. AMD, *7 Series FPGAs Configurable Logic Block User Guide* (UG474): distributed RAM (`RAM32M`), SLICEM.