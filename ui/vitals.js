// Discworld Vitals — panel UI.
//
// Receives a full state snapshot per push from the Lua side and re-renders
// in place. Mirrors the discworld-grouping / discworld-sailing pattern:
// single "state" channel, full snapshot, no diffing.

const SHIELD_KEYS = ["tpa", "eff", "ccc", "bug", "ms"];
const SHIELD_TITLE = {
  eff: "Endorphin's Floating Friend",
  ccc: "Chrenedict's Corporeal Covering",
  bug: "Bugshield",
  ms:  "Major Shield",
  tpa: "Transcendent Pneumatic Alleviator",
};

const xpValueEl = document.getElementById("xp-value");
const xpRateEl  = document.getElementById("xp-rate");
const chartEl     = document.getElementById("xp-chart");
const chartLineEl = document.getElementById("xp-chart-line");
const chartGridEl = document.getElementById("xp-chart-grid");
const chartMaxEl  = document.getElementById("xp-chart-max");
const hpBarEl   = document.getElementById("hp-bar");
const hpFillEl  = document.getElementById("hp-fill");
const hpValueEl = document.getElementById("hp-value");
const gpFillEl  = document.getElementById("gp-fill");
const gpValueEl = document.getElementById("gp-value");
const burdenRowEl = document.getElementById("burden-row");
const burdenFillEl  = document.getElementById("burden-fill");
const burdenValueEl = document.getElementById("burden-value");
const chipEls = {};
for (const k of SHIELD_KEYS) {
  chipEls[k] = document.querySelector(`.chip[data-key="${k}"]`);
}

function hpClass(pct) {
  if (pct === null || pct === undefined) return "";
  if (pct > 70) return "";
  if (pct > 40) return "mid";
  if (pct > 20) return "low";
  return "crit";
}

function renderBar(barEl, fillEl, valueEl, data, kind) {
  if (!data || data.value == null || data.max == null || data.max <= 0) {
    fillEl.style.width = "0%";
    valueEl.textContent = "—";
    if (kind === "hp") barEl.className = "bar hp";
    return;
  }
  const pct = Math.max(0, Math.min(100, (data.value / data.max) * 100));
  fillEl.style.width = pct + "%";
  valueEl.innerHTML =
    `${data.value}<span class="max">/${data.max}</span>`;
  if (kind === "hp") {
    const cls = hpClass(pct);
    barEl.className = "bar hp" + (cls ? " " + cls : "");
  }
}

function renderBurden(percent) {
  if (percent === null || percent === undefined) {
    burdenFillEl.style.width = "0%";
    burdenValueEl.textContent = "—";
    burdenRowEl.classList.remove("high");
    return;
  }
  const p = Math.max(0, Math.min(100, percent));
  burdenFillEl.style.width = p + "%";
  burdenValueEl.textContent = p + "%";
  burdenRowEl.classList.toggle("high", p >= 60);
}

function renderXp(xp, xpRate) {
  xpValueEl.textContent = (xp != null && xp !== "") ? xp : "—";
  if (xpRate != null && xpRate !== "") {
    xpRateEl.textContent = "+" + xpRate + " / hr";
    xpRateEl.classList.remove("unknown");
  } else {
    xpRateEl.textContent = "— / hr";
    xpRateEl.classList.add("unknown");
  }
}

// SVG viewBox dimensions for the chart. CSS stretches it to the container,
// so these are just the coordinate system for plotting, not pixels.
const CHART_W = 100, CHART_H = 40;
const CHART_GRID_LINES = 4;
// The x-axis represents a fixed 60-minute window anchored to "now" on the
// right edge — must match XP_CHART_MAX_POINTS on the Lua side. With fewer
// samples the line grows leftward from x=CHART_W instead of stretching to
// fill the chart, so each new 60s sample advances the line by ~1/60 of
// width from sample one (rather than starting fast and slowing as the
// buffer fills).
const CHART_WINDOW_POINTS = 60;

// Round `value` up to a "nice" ceiling at the leading-digit granularity:
// 12,345 → 20,000; 8,500 → 9,000; 99,000 → 100,000. Matches the intent
// of quow's 100k-step scaling but adapts to the actual data range so a
// 2,000 xp/hr trickle doesn't get squashed against the baseline.
function chartNiceCeil(value) {
  if (!(value > 0)) return 1000;
  const exp = Math.floor(Math.log10(value));
  const step = Math.pow(10, exp);
  return Math.ceil(value / step) * step;
}

function chartFormatRate(n) {
  if (n < 1000) return String(Math.round(n));
  if (n < 1_000_000) return Math.round(n / 1000) + "k";
  return (n / 1_000_000).toFixed(1) + "m";
}

function renderChart(chart) {
  const enabled = chart && chart.enabled !== false;
  chartEl.hidden = !enabled;
  if (!enabled) return;

  let gridStr = "";
  for (let i = 0; i <= CHART_GRID_LINES; i++) {
    const y = (i / CHART_GRID_LINES) * CHART_H;
    gridStr += `<line x1="0" y1="${y}" x2="${CHART_W}" y2="${y}"/>`;
  }
  chartGridEl.innerHTML = gridStr;

  const series = (chart && Array.isArray(chart.series)) ? chart.series : [];
  if (series.length === 0) {
    chartLineEl.setAttribute("points", "");
    chartMaxEl.textContent = "—";
    return;
  }

  let max = 0;
  for (const v of series) if (v > max) max = v;
  const ceil = chartNiceCeil(max);
  chartMaxEl.textContent = chartFormatRate(ceil) + "/hr";

  const n = series.length;
  const pts = [];
  const denom = CHART_WINDOW_POINTS - 1;
  for (let i = 0; i < n; i++) {
    // Newest sample sits at x=CHART_W (right edge = "now"); the i-th oldest
    // is (n-1-i) steps back, mapped onto the fixed-width axis.
    const stepsBack = n - 1 - i;
    const x = CHART_W - (stepsBack / denom) * CHART_W;
    const v = Math.max(0, Math.min(ceil, series[i]));
    const y = CHART_H - (v / ceil) * CHART_H;
    pts.push(x.toFixed(2) + "," + y.toFixed(2));
  }
  chartLineEl.setAttribute("points", pts.join(" "));
}

const SHIELD_STATE_LABEL = { up: "Up", down: "Down", unknown: "Unknown" };
const SHIELD_STATE_COLOR = { up: "ok", down: "bad", unknown: "muted" };

function renderShield(key, shield) {
  const el = chipEls[key];
  if (!el) return;
  const s = (shield && shield.state) || "unknown";
  // 2-state chip vocabulary shared with discworld-grouping: the chip is
  // either "up" (green) or off (dim). down / unknown both render as off; the
  // exact status still shows in the tooltip's Status row below.
  el.classList.remove("up");
  if (s === "up") el.classList.add("up");
  const detail = (shield && shield.detail) ? shield.detail : "";
  const rows = [
    { label: "Status", value: SHIELD_STATE_LABEL[s], valueColor: SHIELD_STATE_COLOR[s] },
  ];
  if (detail) rows.push({ label: "Detail", value: detail });
  el.setAttribute("data-mallard-tooltip", JSON.stringify({
    title: SHIELD_TITLE[key],
    rows,
  }));
}

// Latest known character name, mirrored from state for the context-menu
// header. Null until the Lua side learns who we're logged in as.
let currentCharname = null;

function applyState(state) {
  if (!state || typeof state !== "object") return;
  currentCharname = state.charname || null;
  renderXp(state.xp, state.xp_rate);
  renderChart(state.xp_chart);
  const shields = state.shields || {};
  for (const k of SHIELD_KEYS) renderShield(k, shields[k]);
  renderBar(hpBarEl, hpFillEl, hpValueEl, state.hp, "hp");
  renderBar(null,    gpFillEl, gpValueEl, state.gp, "gp");
  renderBurden(state.burden);
}

// Native right-click context menu (mallard >= 0.11.0). Feature-detected so
// the panel still works on older hosts, where panel.menu is undefined and the
// browser's default menu shows instead. The "Show goals" onClick runs in this
// iframe, so it just posts to the Lua side, which executes the /goals path.
if (panel.menu && typeof panel.menu.show === "function") {
  document.addEventListener("contextmenu", (e) => {
    const header = currentCharname ? `Vitals: ${currentCharname}` : "Vitals";
    panel.menu.show(e, [
      { header: true, label: header },
      { label: "Show goals", onClick: () => panel.post("show_goals", {}) },
    ]);
  });
}

panel.on("state", applyState);
panel.post("ready", {});
