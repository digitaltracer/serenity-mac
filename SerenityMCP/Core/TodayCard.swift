import Foundation

/// The Today card Claude shows for get_today: one self-contained page, since the host's sandbox runs
/// only inline script and style. It talks to the host over postMessage (MCP Apps) and calls this
/// server's own tools to tick, pause and refresh.
public enum TodayCard {
  public static let uri = "ui://serenity/today.html"
  public static let mimeType = "text/html;profile=mcp-app"

  public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Serenity · Today</title>
<style>
:root {
  --bg: #FFFFFF; --footer: #FAFBFC; --border: rgba(15,23,42,.10); --hair: rgba(15,23,42,.07);
  --text: #14171F; --muted: #5B6472; --btn: #FFFFFF; --btn-hover: #F3F5F8; --track: #E6E9EE;
  --accent: #2F5FD0; --accent-text: #2A55BD; --focus-bg: #EEF3FD; --focus-border: #D7E2FA;
  --green: #13795B; --green-bg: #E7F5EF; --warn: #A2560A; --warn-bar: #D08A2E; --box: #9AA3B2; --bar-neutral: #C9CFD8;
  --shadow: 0 1px 2px rgba(15,23,42,.06), 0 6px 24px rgba(15,23,42,.05);
  color-scheme: light;
}
:root[data-theme="dark"] {
  --bg: #151922; --footer: #121620; --border: rgba(255,255,255,.09); --hair: rgba(255,255,255,.06);
  --text: #E7EAF0; --muted: #9AA3B2; --btn: #1B202B; --btn-hover: #222836; --track: #222836;
  --accent: #3767E0; --accent-text: #8DB4FF; --focus-bg: rgba(55,103,224,.12); --focus-border: rgba(141,180,255,.18);
  --green: #1B9C74; --green-bg: rgba(27,156,116,.14); --warn: #F0B866; --warn-bar: #D99A4A; --box: #5A6375; --bar-neutral: #3A4252;
  --shadow: 0 1px 2px rgba(0,0,0,.4);
  color-scheme: dark;
}
* { box-sizing: border-box; }
html, body { margin: 0; background: transparent; }
body { font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "SF Pro Text", Inter, system-ui, sans-serif); font-size: 14px; line-height: 1.45; color: var(--text); -webkit-font-smoothing: antialiased; }
button, input { font: inherit; color: inherit; }
button { cursor: pointer; }
button:disabled { cursor: default; opacity: .55; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.card { background: var(--bg); border: 1px solid var(--border); border-radius: 16px; box-shadow: var(--shadow); overflow: hidden; }
header { display: flex; align-items: center; gap: 10px; padding: 14px 16px 12px; border-bottom: 1px solid var(--hair); }
.titles { flex: 1; min-width: 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; }
h2 { margin: 0; font-size: 15px; font-weight: 600; letter-spacing: -0.01em; }
h3 { margin: 0 0 4px; font-size: 13px; font-weight: 600; color: var(--muted); }
.muted { color: var(--muted); }
.small { font-size: 12px; }
.live { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
.dot { width: 7px; height: 7px; border-radius: 4px; background: var(--green); }
.icon-btn { width: 32px; height: 32px; border-radius: 8px; border: 0; background: transparent; color: var(--muted); display: grid; place-items: center; }
.icon-btn:hover { background: var(--btn-hover); }
.body { padding: 16px; display: flex; flex-direction: column; gap: 18px; }
.focus { border-radius: 12px; background: var(--focus-bg); border: 1px solid var(--focus-border); padding: 14px 16px; display: flex; flex-direction: column; gap: 12px; }
.focus-row { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 16px; }
.focus-text { flex: 1 1 200px; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.eyebrow { font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--accent-text); }
.clock { font-size: 30px; font-weight: 600; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
.controls { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
.btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; min-height: 36px; padding: 0 14px; border-radius: 9px; border: 1px solid var(--border); background: var(--btn); font-size: 13px; font-weight: 500; }
.btn:hover:not(:disabled) { background: var(--btn-hover); }
.btn.square { min-width: 44px; padding: 0 10px; }
.btn.primary { background: var(--accent); border-color: transparent; color: #FFFFFF; }
.btn.primary:hover:not(:disabled) { background: var(--accent); filter: brightness(1.08); }
.track { height: 4px; border-radius: 99px; background: var(--track); overflow: hidden; }
.track > div { height: 4px; border-radius: 99px; background: var(--accent); }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(260px, 100%), 1fr)); gap: 18px; }
.col { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.task { display: flex; align-items: center; gap: 12px; min-height: 44px; padding: 0 6px; margin: 0 -6px; border: 0; border-radius: 8px; background: transparent; text-align: left; width: calc(100% + 12px); }
.task:hover:not(:disabled) { background: var(--btn-hover); }
.box { flex: none; width: 18px; height: 18px; border-radius: 6px; border: 1.5px solid var(--box); display: grid; place-items: center; }
.task[aria-pressed="true"] .box { background: var(--accent); border-color: var(--accent); }
.task[aria-pressed="true"] .t-title { color: var(--muted); text-decoration: line-through; }
.t-text { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.t-title { font-weight: 500; overflow-wrap: anywhere; }
.plan-row { display: flex; align-items: center; gap: 12px; min-height: 44px; }
.plan-time { flex: none; width: 64px; font-size: 12px; font-variant-numeric: tabular-nums; color: var(--muted); }
.plan-bar { flex: none; width: 4px; height: 26px; border-radius: 2px; background: var(--bar-neutral); }
.chips { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.chip { display: inline-flex; align-items: center; gap: 8px; min-height: 36px; padding: 0 12px 0 8px; border-radius: 999px; border: 1px solid var(--border); background: var(--btn); font-size: 13px; font-weight: 500; }
.chip[aria-pressed="true"] { background: var(--green-bg); border-color: transparent; }
.ring { width: 18px; height: 18px; border-radius: 9px; border: 1.5px solid var(--box); display: grid; place-items: center; }
.chip[aria-pressed="true"] .ring { background: var(--green); border-color: var(--green); }
.goals { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(220px, 100%), 1fr)); gap: 12px 18px; }
.goal { display: flex; flex-direction: column; gap: 6px; }
.goal-head { display: flex; justify-content: space-between; gap: 8px; font-size: 13px; }
.bar { position: relative; height: 6px; border-radius: 99px; background: var(--track); }
.bar-fill { height: 6px; border-radius: 99px; background: var(--accent); }
.bar-tick { position: absolute; top: -3px; width: 2px; height: 12px; border-radius: 1px; background: var(--text); }
.behind { color: var(--warn); }
.ahead { color: var(--accent-text); }
footer { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 12px 16px; border-top: 1px solid var(--hair); background: var(--footer); }
.spacer { flex: 1; }
.link { border: 0; background: none; padding: 0 2px; min-height: 36px; font-size: 13px; font-weight: 500; color: var(--accent-text); }
.add { display: flex; gap: 8px; width: 100%; }
.add[hidden] { display: none; }
.add input { flex: 1; min-width: 0; height: 36px; border-radius: 9px; border: 1px solid var(--border); background: var(--btn); padding: 0 12px; }
.status { font-size: 12px; color: var(--muted); padding: 0 16px 12px; background: var(--footer); }
.status:empty { display: none; }
.status.error { color: var(--warn); }
.empty { color: var(--muted); padding: 12px 0; }
.sr { position: absolute; left: -9999px; }
</style>
</head>
<body>
<section class="card" aria-labelledby="title">
  <header>
    <svg width="22" height="22" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#0C1F1A"></rect><rect x="11" y="8" width="10" height="4" rx="2" fill="#F2A03D"></rect><rect x="9" y="14" width="14" height="4" rx="2" fill="#1B9C74"></rect><rect x="7" y="20" width="18" height="4" rx="2" fill="#2E6B58"></rect></svg>
    <div class="titles"><h2 id="title">Today</h2><span id="date" class="muted" style="font-size:13px"></span></div>
    <span class="live"><span class="dot"></span>Live from this Mac</span>
    <button id="expand" class="icon-btn" type="button" aria-label="Open full screen"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"></path></svg></button>
  </header>
  <div id="body" class="body"><div class="empty">Loading your day…</div></div>
  <footer>
    <button id="plan" class="btn" type="button"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"></path></svg><span id="plan-label">Plan my day</span></button>
    <button id="add-toggle" class="btn" type="button" aria-expanded="false">Add a task</button>
    <span class="spacer"></span>
    <button id="open" class="link" type="button">Open in Serenity</button>
    <div id="add-form" class="add" hidden>
      <label for="add-title" class="sr">New task for today</label>
      <input id="add-title" type="text" placeholder="A task for today" autocomplete="off" enterkeyhint="done">
      <button id="add-submit" class="btn primary" type="button">Add</button>
    </div>
  </footer>
  <div id="status" class="status" role="status" aria-live="polite"></div>
</section>
<script>
(function () {
  "use strict";
  var host = window.parent;
  var nextId = 1;
  var pending = {};
  var data = null;
  var receivedAt = 0;
  var busy = false;
  var displayMode = "inline";
  var gotResult = false;
  var clockNodes = null;

  function post(message) { host.postMessage(message, "*"); }

  function request(method, params) {
    var id = nextId++;
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
      post({ jsonrpc: "2.0", id: id, method: method, params: params || {} });
      setTimeout(function () {
        if (pending[id]) { delete pending[id]; reject(new Error("Claude didn't answer in time.")); }
      }, 45000);
    });
  }

  function notify(method, params) { post({ jsonrpc: "2.0", method: method, params: params || {} }); }

  function callTool(name, args) {
    return request("tools/call", { name: name, arguments: args || {} }).then(function (result) {
      if (result && result.isError) {
        var text = (result.content || []).map(function (c) { return c.text || ""; }).join(" ");
        throw new Error(text || "Serenity couldn't do that.");
      }
      return result;
    });
  }

  window.addEventListener("message", function (event) {
    if (event.source !== host) return;
    var msg = event.data;
    if (!msg || msg.jsonrpc !== "2.0") return;
    if (msg.method === undefined && msg.id !== undefined) {
      var waiter = pending[msg.id];
      if (!waiter) return;
      delete pending[msg.id];
      if (msg.error) waiter.reject(new Error(msg.error.message || "Something went wrong."));
      else waiter.resolve(msg.result);
      return;
    }
    switch (msg.method) {
      case "ui/notifications/tool-result":
        accept(msg.params);
        break;
      case "ui/notifications/host-context-changed":
        applyContext(msg.params || {});
        break;
      case "ui/resource-teardown":
        stopped = true;
        break;
    }
    // Requests from the host need an answer; we have nothing to add beyond acknowledging.
    if (msg.method !== undefined && msg.id !== undefined) post({ jsonrpc: "2.0", id: msg.id, result: {} });
  });

  var stopped = false;

  function applyContext(context) {
    if (context.theme === "dark" || context.theme === "light") document.documentElement.setAttribute("data-theme", context.theme);
    if (context.displayMode) displayMode = context.displayMode;
    var vars = context.styles && context.styles.variables;
    if (vars && vars["--font-sans"]) document.documentElement.style.setProperty("--font-sans", vars["--font-sans"]);
    var expand = document.getElementById("expand");
    expand.setAttribute("aria-label", displayMode === "fullscreen" ? "Back to the chat" : "Open full screen");
  }

  function accept(result) {
    if (!result) return;
    var value = result.structuredContent;
    if (!value && result.content && result.content[0] && result.content[0].text) {
      try { value = JSON.parse(result.content[0].text); } catch (e) { value = null; }
    }
    if (!value || typeof value.date !== "string") return;
    gotResult = true;
    data = value;
    receivedAt = Date.now();
    render();
  }

  function refresh() {
    return callTool("get_today").then(accept);
  }

  function setStatus(text, isError) {
    var status = document.getElementById("status");
    status.textContent = text || "";
    status.className = "status" + (isError ? " error" : "");
  }

  // Runs a change, then reloads the day so the card shows what Serenity actually saved.
  function act(name, args) {
    if (busy) return Promise.resolve();
    busy = true;
    setStatus("");
    setDisabled(true);
    return callTool(name, args)
      .then(refresh)
      .catch(function (error) { setStatus(error.message, true); return refresh().catch(function () {}); })
      .then(function () { busy = false; setDisabled(false); });
  }

  function setDisabled(disabled) {
    var buttons = document.querySelectorAll("#body button");
    for (var i = 0; i < buttons.length; i++) buttons[i].disabled = disabled;
  }

  function el(tag, attrs) {
    var node = document.createElement(tag);
    if (attrs) for (var key in attrs) {
      if (key === "text") node.textContent = attrs[key];
      else if (key === "className") node.className = attrs[key];
      else if (key.indexOf("on") === 0) node.addEventListener(key.slice(2), attrs[key]);
      else node.setAttribute(key, attrs[key]);
    }
    for (var i = 2; i < arguments.length; i++) {
      var child = arguments[i];
      if (child === null || child === undefined || child === false) continue;
      node.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
    }
    return node;
  }

  function svg(markup) {
    var holder = document.createElement("span");
    holder.setAttribute("aria-hidden", "true");
    holder.style.display = "inline-flex";
    holder.innerHTML = markup; // static icon markup only, never user data
    return holder;
  }

  var CHECK = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"></path></svg>';
  var PAUSE = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"></rect><rect x="14" y="5" width="4" height="14" rx="1"></rect></svg>';
  var PLAY = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M7 5l12 7-12 7z"></path></svg>';

  function dayLabel(day) {
    var parts = day.split("-").map(Number);
    var date = new Date(parts[0], parts[1] - 1, parts[2]);
    return date.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" });
  }

  function timeLabel(iso) {
    var date = new Date(iso);
    if (isNaN(date)) return "";
    return date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  }

  function clockText(seconds) {
    seconds = Math.max(0, Math.round(seconds));
    var h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
    var mm = h > 0 ? String(m).padStart(2, "0") : String(m);
    return (h > 0 ? h + ":" : "") + mm + ":" + String(s).padStart(2, "0");
  }

  function renderFocus(focus) {
    if (!focus) {
      return el("div", { className: "focus" },
        el("div", { className: "focus-row" },
          el("div", { className: "focus-text" },
            el("span", { className: "eyebrow", text: "Focus" }),
            el("span", { className: "muted", text: "No session running." })),
          el("button", { className: "btn primary", type: "button", onclick: function () { act("start_focus", {}); } }, "Start focus")));
    }
    var running = focus.status === "running";
    var hasLength = typeof focus.lengthMinutes === "number";
    var clock = el("span", { className: "clock" });
    var fill = hasLength ? el("div") : null;
    clockNodes = { clock: clock, fill: fill, focus: focus };
    var link = focus.taskTitle ? "Linked to " + focus.taskTitle : (focus.journalEntryId ? "Linked to a journal entry" : null);
    var controls = el("div", { className: "controls" },
      hasLength ? el("button", { className: "btn square", type: "button", "aria-label": "Five minutes less", onclick: function () { act("extend_focus", { minutes: -5 }); } }, "−5") : null,
      hasLength ? el("button", { className: "btn square", type: "button", "aria-label": "Five minutes more", onclick: function () { act("extend_focus", { minutes: 5 }); } }, "+5") : null,
      el("button", { className: "btn primary square", type: "button", "aria-label": running ? "Pause" : "Resume", onclick: function () { act(running ? "pause_focus" : "resume_focus", {}); } }, svg(running ? PAUSE : PLAY)),
      el("button", { className: "btn", type: "button", onclick: function () { act("finish_focus", {}); } }, "Finish"));
    var node = el("div", { className: "focus" },
      el("div", { className: "focus-row" },
        el("div", { className: "focus-text" },
          el("span", { className: "eyebrow", text: running ? "Focus session" : "Focus · paused" }),
          el("strong", { style: "font-size:15px;font-weight:600;overflow-wrap:anywhere", text: focus.title }),
          link ? el("span", { className: "muted small", text: link }) : null),
        clock,
        controls),
      fill ? el("div", { className: "track" }, fill) : null);
    tick();
    return node;
  }

  function tick() {
    if (!clockNodes) return;
    var focus = clockNodes.focus;
    var elapsed = focus.status === "running" ? (Date.now() - receivedAt) / 1000 : 0;
    if (typeof focus.remainingSeconds === "number") {
      var left = Math.max(focus.remainingSeconds - elapsed, 0);
      clockNodes.clock.textContent = clockText(left);
      var total = focus.lengthMinutes * 60;
      if (clockNodes.fill && total > 0) clockNodes.fill.style.width = Math.min(100, Math.round((1 - left / total) * 100)) + "%";
    } else {
      clockNodes.clock.textContent = clockText(focus.focusedSeconds + elapsed);
    }
  }

  function taskButton(task) {
    var meta = [task.project, task.topThree ? "Top three" : null].filter(Boolean).join(" · ");
    return el("button", {
      className: "task", type: "button", "aria-pressed": task.done ? "true" : "false",
      onclick: function () { act("set_task_done", { id: task.id, done: !task.done }); }
    },
      el("span", { className: "box", "aria-hidden": "true" }, task.done ? svg(CHECK) : null),
      el("span", { className: "t-text" },
        el("span", { className: "t-title", text: task.title }),
        meta ? el("span", { className: "muted small", text: meta }) : null));
  }

  function renderTasks() {
    // Ticked tasks stay, so a mis-tap can be undone right here.
    var rest = data.dueToday.filter(function (t) { return !t.done; }).concat(data.dueToday.filter(function (t) { return t.done; }));
    var tasks = data.topThree.concat(rest).slice(0, 6);
    var col = el("div", { className: "col" }, el("h3", { text: data.topThree.length ? "Top three and due today" : "Due today" }));
    if (!tasks.length) col.appendChild(el("span", { className: "muted", text: "Nothing due today." }));
    tasks.forEach(function (task) { col.appendChild(taskButton(task)); });
    if (data.overdue.length) col.appendChild(el("span", { className: "small behind", style: "padding-top:6px", text: data.overdue.length + " overdue" }));
    return col;
  }

  function renderPlan() {
    var now = Date.now();
    var items = data.plan.filter(function (item) { return new Date(item.end).getTime() > now && !item.done; }).slice(0, 4);
    var col = el("div", { className: "col" }, el("h3", { text: "Rest of the day" }));
    if (!items.length) col.appendChild(el("span", { className: "muted", text: "Nothing else scheduled." }));
    items.forEach(function (item) {
      var started = new Date(item.start).getTime() <= now;
      var bar = el("span", { className: "plan-bar" });
      if (item.kind === "focus") bar.style.background = "var(--accent)";
      col.appendChild(el("div", { className: "plan-row" },
        el("span", { className: "plan-time", text: started ? "Now" : timeLabel(item.start) }),
        bar,
        el("span", { className: "t-text" },
          el("span", { className: "t-title", text: item.title }),
          el("span", { className: "muted small", text: (item.kind === "calendar" ? "Calendar" : item.kind === "focus" ? "Focus" : "Task") + " · until " + timeLabel(item.end) }))));
    });
    return col;
  }

  function renderRoutines() {
    var due = data.routines.filter(function (r) { return r.scheduledToday || r.today; });
    if (!due.length) return null;
    var chips = el("div", { className: "chips" }, el("span", { style: "font-size:13px;font-weight:600;margin-right:4px", className: "muted", text: "Routines" }));
    due.forEach(function (routine) {
      var done = routine.today === "done";
      chips.appendChild(el("button", {
        className: "chip", type: "button", "aria-pressed": done ? "true" : "false",
        onclick: function () { act("set_routine_done", { id: routine.id, done: !done }); }
      },
        el("span", { className: "ring", "aria-hidden": "true" }, done ? svg(CHECK) : null),
        routine.title,
        el("span", { className: "muted small", style: "font-weight:400", text: routine.streak })));
    });
    return chips;
  }

  function renderGoals() {
    var goals = data.goals.slice(0, 4);
    if (!goals.length) return null;
    var wrap = el("div", { className: "goals" });
    goals.forEach(function (goal) {
      var pct = goal.target > 0 ? Math.min(100, Math.round(goal.current / goal.target * 100)) : 0;
      var fill = el("div", { className: "bar-fill", style: "width:" + pct + "%" });
      if (goal.paceState === "behind") fill.style.background = "var(--warn-bar)";
      var bar = el("div", { className: "bar" }, fill);
      if (typeof goal.expected === "number" && goal.target > 0) {
        bar.appendChild(el("div", { className: "bar-tick", style: "left:" + Math.min(99, Math.round(goal.expected / goal.target * 100)) + "%" }));
      }
      wrap.appendChild(el("div", { className: "goal" },
        el("div", { className: "goal-head" },
          el("span", { style: "font-weight:500;overflow-wrap:anywhere", text: goal.title }),
          el("span", { className: goal.paceState === "behind" ? "behind" : goal.paceState === "ahead" ? "ahead" : "muted", text: goal.pace })),
        bar,
        el("span", { className: "muted small", text: goal.progress })));
    });
    return wrap;
  }

  function render() {
    document.getElementById("date").textContent = dayLabel(data.date);
    var hour = new Date().getHours();
    document.getElementById("plan-label").textContent = hour < 12 ? "Plan my day" : "Plan the rest of my day";
    var body = document.getElementById("body");
    clockNodes = null;
    body.replaceChildren(
      renderFocus(data.focus),
      el("div", { className: "grid" }, renderTasks(), renderPlan()),
      renderRoutines(),
      renderGoals());
    if (data.inboxCount > 0) body.appendChild(el("span", { className: "muted small", text: data.inboxCount + (data.inboxCount === 1 ? " capture waits" : " captures wait") + " in the inbox." }));
    if (busy) setDisabled(true);
  }

  function planMessage() {
    var open = data.topThree.concat(data.dueToday).filter(function (t) { return !t.done; }).map(function (t) { return t.title; });
    var now = Date.now();
    var fixed = data.plan.filter(function (p) { return p.kind === "calendar" && new Date(p.end).getTime() > now; })
      .map(function (p) { return p.title + " at " + timeLabel(p.start); });
    var text = "Using Serenity, plan the rest of my day. Still open: " + (open.length ? open.join("; ") : "nothing due") + ".";
    if (fixed.length) text += " Fixed: " + fixed.join("; ") + ".";
    if (data.focus) text += " I'm in a focus session on " + data.focus.title + ".";
    return text.replace(/\s+/g, " ").slice(0, 7500);
  }

  document.getElementById("plan").addEventListener("click", function () {
    if (!data) return;
    request("ui/message", { role: "user", content: [{ type: "text", text: planMessage() }] })
      .then(function () { setStatus("Added to your message. Send it when you're ready."); })
      .catch(function (error) { setStatus(error.message, true); });
  });

  document.getElementById("add-toggle").addEventListener("click", function () {
    var form = document.getElementById("add-form");
    form.hidden = !form.hidden;
    this.setAttribute("aria-expanded", form.hidden ? "false" : "true");
    if (!form.hidden) document.getElementById("add-title").focus();
  });

  // No <form>: sandboxes without allow-forms drop the submit, so Enter and the button are wired directly.
  function addTask() {
    var input = document.getElementById("add-title");
    var title = input.value.trim();
    if (!title || !data) return;
    act("add_task", { title: title, due: data.date }).then(function () { input.value = ""; });
  }
  document.getElementById("add-submit").addEventListener("click", addTask);
  document.getElementById("add-title").addEventListener("keydown", function (event) {
    if (event.key === "Enter" && !event.isComposing) { event.preventDefault(); addTask(); }
  });

  document.getElementById("open").addEventListener("click", function () {
    callTool("open_serenity").catch(function (error) { setStatus(error.message, true); });
  });

  document.getElementById("expand").addEventListener("click", function () {
    request("ui/request-display-mode", { mode: displayMode === "fullscreen" ? "inline" : "fullscreen" })
      .then(function (result) { if (result && result.mode) applyContext({ displayMode: result.mode }); })
      .catch(function () {});
  });

  if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
    document.documentElement.setAttribute("data-theme", "dark");
  }

  if (window.ResizeObserver) {
    new ResizeObserver(function () {
      // The body, not the document: the document is never shorter than the frame, so it couldn't shrink.
      var box = document.body.getBoundingClientRect();
      notify("ui/notifications/size-changed", { width: Math.ceil(box.width), height: Math.ceil(box.height) });
    }).observe(document.body);
  }

  setInterval(tick, 1000);
  setInterval(function () {
    if (!stopped && !busy && data && document.visibilityState === "visible") refresh().catch(function () {});
  }, 30000);

  request("ui/initialize", {
    protocolVersion: "2026-01-26",
    appInfo: { name: "Serenity Today", version: "1.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
  }).then(function (result) {
    applyContext((result && result.hostContext) || {});
    notify("ui/notifications/initialized", {});
    // The host normally sends the get_today result; ask for it ourselves if it doesn't.
    setTimeout(function () { if (!gotResult) refresh().catch(function (error) { setStatus(error.message, true); }); }, 2500);
  }).catch(function (error) { setStatus(error.message, true); });
})();
</script>
</body>
</html>
"""#
}
