// Discworld Vitals — panel UI.
//
// Receives a full state snapshot per push from the Lua side and re-renders
// in place. Mirrors the discworld-grouping / discworld-sailing pattern:
// single "state" channel, full snapshot, no diffing.

const SHIELD_KEYS = ["eff", "ccc", "bug", "ms", "tpa"];
const SHIELD_TITLE = {
  eff: "Endorphin's Floating Friend",
  ccc: "Chrenedict's Corporeal Covering",
  bug: "Bugshield",
  ms:  "Major Shield",
  tpa: "Transcendent Pneumatic Alleviator",
};

const xpValueEl = document.getElementById("xp-value");
const xpRateEl  = document.getElementById("xp-rate");
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

function renderShield(key, shield) {
  const el = chipEls[key];
  if (!el) return;
  const s = (shield && shield.state) || "unknown";
  el.classList.remove("up", "down", "unknown");
  el.classList.add(s);
  const baseTitle = SHIELD_TITLE[key];
  const detail = (shield && shield.detail) ? shield.detail : null;
  if (s === "up" && detail)        el.title = `${baseTitle} — ${detail}`;
  else if (s === "down" && detail) el.title = `${baseTitle} — ${detail}`;
  else if (s === "down")           el.title = `${baseTitle} — down`;
  else if (s === "unknown")        el.title = `${baseTitle} — unknown`;
  else                             el.title = baseTitle;
}

function applyState(state) {
  if (!state || typeof state !== "object") return;
  renderXp(state.xp, state.xp_rate);
  const shields = state.shields || {};
  for (const k of SHIELD_KEYS) renderShield(k, shields[k]);
  renderBar(hpBarEl, hpFillEl, hpValueEl, state.hp, "hp");
  renderBar(null,    gpFillEl, gpValueEl, state.gp, "gp");
  renderBurden(state.burden);
}

panel.on("state", applyState);
panel.post("ready", {});
