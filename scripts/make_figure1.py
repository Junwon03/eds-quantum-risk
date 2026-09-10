from pathlib import Path
import math

import numpy as np
import pandas as pd

import matplotlib
matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib import font_manager


# ============================================================
# Paths
# ============================================================

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
RESULTS = ROOT / "results"
FIGURES = ROOT / "figures"
FIGURES.mkdir(exist_ok=True)


# ============================================================
# Load corrected frozen data
# ============================================================

addr = pd.read_csv(DATA / "eds_addrbal_20260101_t5_bip30fix.csv")
baseline = pd.read_csv(RESULTS / "baseline_bip30_corrected.csv").iloc[0]

balances = (
    addr.loc[addr["balance_sats"] > 0, "balance_sats"]
    .to_numpy(dtype=float)
)
balances.sort()
balances = balances[::-1]

B = balances.sum()
H0 = float(baseline["baseline_hhi"])
N0 = int(baseline["baseline_nakamoto_33"])

alpha = 0.10
tau = 0.33
target = tau * B

scaled = balances * (1 - alpha)
scaled_cum = np.cumsum(scaled)


# ============================================================
# Nakamoto coefficient under defensive dispersion
# ============================================================

def nakamoto_piD(m: int) -> int:
    new_balance = alpha * B / m

    r = np.searchsorted(
        -scaled,
        -new_balance,
        side="left",
    )

    pre_sum = scaled_cum[r - 1] if r > 0 else 0.0

    if pre_sum >= target:
        return int(
            np.searchsorted(
                scaled_cum,
                target,
                side="left",
            ) + 1
        )

    after_new = pre_sum + m * new_balance

    if after_new >= target:
        need_new = int(
            math.ceil(
                (target - pre_sum) / new_balance - 1e-12
            )
        )
        return r + need_new

    tail_cum = scaled_cum[r:] - pre_sum

    need_tail = int(
        np.searchsorted(
            tail_cum,
            target - after_new,
            side="left",
        ) + 1
    )

    return r + m + need_tail


# ============================================================
# Verify exact boundaries
# ============================================================

m_check = np.arange(1, 5001)

hhi_check = (
    (1 - alpha) ** 2 * H0
    + alpha ** 2 / m_check
)

delta_hhi_check = hhi_check - H0

naka_check = np.array(
    [nakamoto_piD(int(x)) for x in m_check]
)

delta_n_check = naka_check - N0

m_hhi = int(
    m_check[np.where(delta_hhi_check < 0)[0][0]]
)

m_naka_equal = int(
    m_check[np.where(delta_n_check == 0)[0][0]]
)

m_naka_improve = int(
    m_check[np.where(delta_n_check > 0)[0][0]]
)

assert m_hhi == 1569
assert m_naka_equal == 2559
assert m_naka_improve == 2560

print("===== THRESHOLD CHECK =====")
print("Baseline HHI:", H0)
print("Baseline N(0.33):", N0)
print("HHI improves from:", m_hhi)
print("N(0.33) equals baseline at:", m_naka_equal)
print("N(0.33) improves from:", m_naka_improve)


# ============================================================
# Plot data
# ============================================================

m = np.arange(1200, 3001)

delta_hhi = (
    (
        (1 - alpha) ** 2 * H0
        + alpha ** 2 / m
    ) - H0
) * 1e6

delta_n = np.array(
    [nakamoto_piD(int(x)) - N0 for x in m]
)


# ============================================================
# Font
# ============================================================

# Fixed cross-platform font. DejaVu Serif ships with Matplotlib,
# so macOS and GitHub Actions use the same typeface.
SERIF = "STIXGeneral"
print("Figure font:", SERIF)
print("Matplotlib version:", matplotlib.__version__)

plt.rcParams.update({
    "font.family": SERIF,
    "mathtext.fontset": "stix",
    "font.size": 11.0,
    "axes.titlesize": 14.3,
    "axes.labelsize": 13.2,
    "xtick.labelsize": 10.8,
    "ytick.labelsize": 10.8,
    "axes.linewidth": 0.9,
    "lines.linewidth": 2.0,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
})


# ============================================================
# Colors
# ============================================================

MINT = "#EAF4F1"
WHITE = "#FFFFFF"
SHADE = "#E4F0FA"
BLUE = "#087FD0"
GRID = "#D5DDE1"
BLACK = "#111111"
TEXT_BLUE = "#173B73"


# ============================================================
# Figure canvas
# ============================================================

fig = plt.figure(
    figsize=(9.0, 9.0),
    facecolor=MINT,
)


# ============================================================
# Panel A
# ============================================================

axA = fig.add_axes([
    0.106,   # left
    0.577,   # bottom
    0.852,   # width
    0.372,   # height
])

axA.set_facecolor(WHITE)

axA.axvspan(
    1569,
    2558,
    facecolor=SHADE,
    linewidth=0,
    zorder=0,
)

axA.plot(
    m,
    delta_hhi,
    color=BLUE,
    linewidth=2.0,
    zorder=3,
)

axA.axhline(
    0,
    color=BLUE,
    linestyle="--",
    linewidth=1.15,
)

axA.axvline(
    1569,
    color=BLUE,
    linestyle=":",
    linewidth=1.25,
)

axA.set_xlim(1200, 3000)
axA.set_ylim(-3.25, 2.25)

axA.set_xticks(np.arange(1200, 3001, 200))
axA.tick_params(axis="x", labelbottom=False)

axA.set_ylabel(
    r"$\Delta$HHI ($\times 10^{-6}$)",
    labelpad=8,
)

axA.yaxis.set_label_coords(-0.073, 0.50)

axA.set_title(
    r"A. HHI under defensive dispersion "
    r"($\alpha = 10\%$)",
    loc="left",
    fontweight="bold",
    fontsize=14.3,
    pad=7,
)

# Data-coordinate placement: stable relative to the curve/thresholds.
axA.text(
    1605,
    1.90,
    "HHI threshold\n"
    r"$m = 1{,}569$",
    ha="left",
    va="top",
    fontsize=10.8,
    color=BLACK,
)

axA.text(
    2110,
    0.85,
    "Disagreement region\n"
    r"$m = 1{,}569$–$2{,}558$",
    ha="center",
    va="center",
    fontsize=11.2,
    color=TEXT_BLUE,
)

axA.grid(
    True,
    color=GRID,
    linewidth=0.65,
    alpha=0.50,
)

axA.set_axisbelow(True)
axA.spines["top"].set_visible(False)
axA.spines["right"].set_visible(False)

axA.tick_params(
    direction="out",
    length=4,
    width=0.8,
)


# ============================================================
# Panel B
# ============================================================

axB = fig.add_axes([
    0.106,
    0.133,
    0.852,
    0.360,
])

axB.set_facecolor(WHITE)

axB.axvspan(
    1569,
    2558,
    facecolor=SHADE,
    linewidth=0,
    zorder=0,
)

axB.plot(
    m,
    delta_n,
    color=BLUE,
    linewidth=2.0,
    drawstyle="steps-post",
    zorder=3,
)

axB.axhline(
    0,
    color=BLUE,
    linestyle="--",
    linewidth=1.15,
)

axB.axvline(
    1569,
    color=BLUE,
    linestyle=":",
    linewidth=1.25,
)

axB.axvline(
    2559,
    color=BLUE,
    linestyle="-.",
    linewidth=1.25,
)

axB.set_xlim(1200, 3000)
axB.set_ylim(-1400, 575)

axB.set_xticks(np.arange(1200, 3001, 200))

axB.set_xlabel(
    r"Number of new recipient addresses ($m$)",
    labelpad=7,
)

axB.set_ylabel(
    r"$\Delta N(0.33)$",
    labelpad=8,
)

axB.yaxis.set_label_coords(-0.080, 0.50)

axB.set_title(
    r"B. Nakamoto coefficient under defensive dispersion "
    r"($\alpha = 10\%$)",
    loc="left",
    fontweight="bold",
    fontsize=14.3,
    pad=7,
)

axB.text(
    1605,
    480,
    "HHI threshold\n"
    r"$m = 1{,}569$",
    ha="left",
    va="top",
    fontsize=10.8,
    color=BLACK,
)

axB.text(
    2110,
    455,
    "Disagreement region\n"
    r"$m = 1{,}569$–$2{,}558$",
    ha="center",
    va="top",
    fontsize=11.2,
    color=TEXT_BLUE,
)

# Deliberately to the RIGHT of m=2559 with clear separation from the line.
axB.text(
    2605,
    485,
    r"$N(0.33)$ baseline"
    "\n"
    r"$m = 2{,}559$",
    ha="left",
    va="top",
    fontsize=10.8,
    color=BLACK,
)

axB.grid(
    True,
    color=GRID,
    linewidth=0.65,
    alpha=0.50,
)

axB.set_axisbelow(True)
axB.spines["top"].set_visible(False)
axB.spines["right"].set_visible(False)

axB.tick_params(
    direction="out",
    length=4,
    width=0.8,
)


# ============================================================
# Note
# ============================================================

# Single text object avoids spacing differences across platforms.
fig.text(
    0.027,
    0.021,
    r"$\mathbf{Note:}$ Shaded area indicates the metric-disagreement region "
    r"($m = 1{,}569$–$2{,}558$).",
    fontsize=10.4,
    ha="left",
    va="bottom",
)


# ============================================================
# Output
# ============================================================

png_path = FIGURES / "Figure1_FRL_final.png"
pdf_path = FIGURES / "Figure1_FRL_final.pdf"
csv_path = FIGURES / "Figure1_source_data.csv"

# IMPORTANT:
# Do NOT use bbox_inches="tight".
# The manually specified 9x9 geometry should remain fixed.
fig.savefig(
    png_path,
    dpi=600,
    facecolor=MINT,
)

fig.savefig(
    pdf_path,
    facecolor=MINT,
)

plt.close(fig)


# ============================================================
# Source-data export
# ============================================================

pd.DataFrame({
    "m": m,
    "delta_hhi_x1e6": delta_hhi,
    "delta_nakamoto_033": delta_n,
}).to_csv(
    csv_path,
    index=False,
)

print()
print("===== OUTPUT =====")
print(png_path)
print(pdf_path)
print(csv_path)
