# CDCKIT — Clock Domain Crossing Toolkit
## Hardware Architecture Specification (HAS) & Micro-Architecture Specification (MAS)

| Field | Value |
|---|---|
| Document | CDCKIT-SPEC-001 |
| IP | `cdckit` — Library of CDC primitives + parameterizable asynchronous FIFO |
| IP version | 1.0 (target) |
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
