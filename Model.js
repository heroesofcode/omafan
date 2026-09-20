.pragma library

// Shared, UI-free logic for Omafan.
//
// Panel.qml owns pixels; this file owns the defaults, the curve preview and
// the command handed to omafan-apply. That script stays the only thing that
// writes configuration, so the panel and the CLI cannot disagree.

// Mirrors manifest.json's barWidget.defaults, the defaults block in
// omafan-apply, and the `defaults()` function in omafan-daemon.
//
// Four copies on purpose: each has to work when the others have not spoken.
// The shell hands a freshly enabled widget an empty settings object, and the
// daemon has to run before the panel has ever been opened. Change one of them,
// change all four.
var DEFAULTS = {
  enabled: true,

  // Below tempLow the fan is left at the factory floor; at tempHigh it is at
  // rpmMax; in between the floor is linear.
  //
  // 65/92 is calibrated against measured behaviour on a MacBookAir7,2. That
  // machine rests in the low-to-mid sixties, so a threshold below 65 has the
  // fan working during ordinary browsing and never stopping. Under load with
  // no fan help it reached 90C; the CPU throttles at 105C. So: silent through
  // the sixties, ramping hard through the eighties, flat out by 92C.
  tempLow: 65,
  tempHigh: 92,

  rpmMin: 1200,
  rpmMax: 6500,

  // Wider than the temperature's own jitter: tick-to-tick swings of 8C were
  // measured here, and a band narrower than that makes the fan hunt.
  hysteresis: 8,
  interval: 5
}

function defaultFor(key) {
  return DEFAULTS.hasOwnProperty(key) ? DEFAULTS[key] : ""
}

function settingsFor(get) {
  var out = {}
  for (var key in DEFAULTS) {
    if (DEFAULTS.hasOwnProperty(key)) out[key] = get(key)
  }
  return out
}

function commandFor(scriptPath, get) {
  return ["bash", scriptPath, JSON.stringify(settingsFor(get))]
}

// The floor the curve asks for at a given temperature. Same arithmetic as
// omafan-daemon's floor_for, so the panel's preview cannot drift from what the
// daemon will actually do.
function floorFor(temp, get) {
  var lo = get("tempLow"), hi = get("tempHigh")
  var rlo = get("rpmMin"), rhi = get("rpmMax")
  if (hi <= lo) hi = lo + 1
  if (temp <= lo) return rlo
  if (temp >= hi) return rhi
  return Math.round(rlo + ((temp - lo) * (rhi - rlo)) / (hi - lo))
}

// Percentage of the fan's range, for the meter in the panel.
function loadFraction(rpm, min, max) {
  if (!max || max <= min) return 0
  var f = (rpm - min) / (max - min)
  return f < 0 ? 0 : (f > 1 ? 1 : f)
}

// What the bar button shows: the temperature, because that is the number that
// tells you whether anything is wrong.
function barText(status) {
  if (!status || !status.supported) return "—"
  return status.temp + "°"
}

// One-line description for the bar tooltip.
function summary(get, status) {
  if (!status || !status.supported) return "No Apple SMC fan on this machine"
  if (status.service === "absent") return "Not installed — run omafan-install"
  if (!get("enabled")) return "Omafan off · " + status.temp + "°C · " + status.rpm + " RPM"
  if (status.service !== "active") return "Service stopped · " + status.temp + "°C · " + status.rpm + " RPM"
  return status.temp + "°C · fan " + status.rpm + " RPM · floor " + status.floor
}
