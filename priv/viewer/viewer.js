(function () {
  "use strict";
  const data = JSON.parse(document.getElementById("outlaw-data").textContent);
  const BIG = 500;
  const varNames = Array.from(new Set(data.nodes.flatMap((n) => Object.keys(n.vars)))).sort();
  const actions = Array.from(new Set(data.edges.map((e) => e.action))).sort();
  const highlight = new Set(data.highlight);
  const state = { keepVars: new Set(varNames), hiddenActions: new Set(), visible: null };

  const out = new Map();
  const inn = new Map();
  for (const e of data.edges) {
    if (!out.has(e.source)) out.set(e.source, []);
    if (!inn.has(e.target)) inn.set(e.target, []);
    out.get(e.source).push(e);
    inn.get(e.target).push(e);
  }

  if (data.nodes.length > BIG) {
    state.visible = new Set(highlight);
    let frontier = data.nodes.filter((n) => n.initial).map((n) => n.id);
    frontier.forEach((id) => state.visible.add(id));
    for (let depth = 0; depth < 2; depth++) {
      const next = [];
      for (const id of frontier) {
        for (const e of out.get(id) || []) {
          if (!state.visible.has(e.target)) { state.visible.add(e.target); next.push(e.target); }
        }
      }
      frontier = next;
    }
  }

  const collapsed = () => state.keepVars.size < varNames.length;
  const keyOf = (n) => varNames.filter((v) => state.keepVars.has(v)).map((v) => v + "=" + n.vars[v]).join("\u0000");

  function elements() {
    const groups = new Map();
    const groupOf = new Map();
    for (const n of data.nodes) {
      if (state.visible && !state.visible.has(n.id)) continue;
      const gid = collapsed() ? "g:" + keyOf(n) : n.id;
      groupOf.set(n.id, gid);
      let g = groups.get(gid);
      if (!g) {
        g = { id: gid, vars: {}, initial: false, members: 0, highlighted: false };
        for (const v of varNames) if (state.keepVars.has(v)) g.vars[v] = n.vars[v];
        groups.set(gid, g);
      }
      g.members += 1;
      g.initial = g.initial || n.initial;
      g.highlighted = g.highlighted || highlight.has(n.id);
    }
    const els = [];
    for (const g of groups.values()) {
      const lines = Object.entries(g.vars).map(([k, v]) => k + " = " + v);
      if (g.members > 1) lines.push("(" + g.members + " states)");
      const classes = [g.initial ? "initial" : "", g.highlighted ? "hl" : ""].join(" ").trim();
      els.push({ group: "nodes", data: { id: g.id, label: lines.join("\n"), vars: g.vars, members: g.members }, classes });
    }
    const seen = new Set();
    for (const e of data.edges) {
      if (state.hiddenActions.has(e.action)) continue;
      const s = groupOf.get(e.source);
      const t = groupOf.get(e.target);
      if (!s || !t) continue;
      const id = s + "|" + e.action + "|" + t;
      if (seen.has(id)) continue;
      seen.add(id);
      const hl = highlight.has(e.source) && highlight.has(e.target);
      els.push({ group: "edges", data: { id, source: s, target: t, label: e.action }, classes: hl ? "hl" : "" });
    }
    return els;
  }

  const css = getComputedStyle(document.documentElement);
  const color = (name) => css.getPropertyValue(name).trim();
  const lineCount = (ele) => ele.data("label").split("\n").length;
  const longest = (ele) => Math.max(...ele.data("label").split("\n").map((l) => l.length));

  const cy = cytoscape({
    container: document.getElementById("graph"),
    wheelSensitivity: 0.2,
    style: [
      { selector: "node", style: {
        shape: "round-rectangle", label: "data(label)", "text-wrap": "wrap", "text-valign": "center",
        "font-family": "ui-monospace, monospace", "font-size": 10, color: color("--fg"),
        width: (ele) => Math.max(40, longest(ele) * 6.2 + 16), height: (ele) => lineCount(ele) * 13 + 12,
        "background-color": color("--node"), "border-width": 1, "border-color": color("--border") } },
      { selector: "node.initial", style: { "border-width": 3, "border-color": color("--initial") } },
      { selector: "node.hl", style: { "background-color": color("--hl-bg"), "border-color": color("--hl"), "border-width": 3 } },
      { selector: "edge", style: {
        "curve-style": "bezier", "target-arrow-shape": "triangle", label: "data(label)", "font-size": 9,
        color: color("--muted"), "line-color": color("--edge"), "target-arrow-color": color("--edge"),
        "text-background-color": color("--bg"), "text-background-opacity": 1, "text-background-padding": "2px" } },
      { selector: "edge.hl", style: { "line-color": color("--hl"), "target-arrow-color": color("--hl"), width: 3 } }
    ]
  });

  function render() {
    cy.elements().remove();
    cy.add(elements());
    const roots = cy.nodes(".initial");
    cy.layout({ name: "breadthfirst", directed: true, roots: roots.length ? roots : undefined, spacingFactor: 1.1, animate: false }).run();
    document.getElementById("count").textContent = cy.nodes().length + " shown of " + data.nodes.length + " states";
  }

  cy.on("tap", "node", (evt) => {
    const d = evt.target.data();
    const panel = document.getElementById("details");
    panel.replaceChildren();
    const title = document.createElement("p");
    title.textContent = d.members > 1 ? d.members + " merged states" : "One state";
    panel.appendChild(title);
    const table = document.createElement("table");
    for (const [k, v] of Object.entries(d.vars)) {
      const row = table.insertRow();
      row.insertCell().textContent = k;
      const cell = row.insertCell();
      cell.textContent = v;
      cell.className = "value";
    }
    panel.appendChild(table);
  });

  cy.on("dbltap", "node", (evt) => {
    if (!state.visible || collapsed()) return;
    const id = evt.target.id();
    for (const e of (out.get(id) || []).concat(inn.get(id) || [])) {
      state.visible.add(e.source);
      state.visible.add(e.target);
    }
    render();
  });

  function checkboxes(containerId, items, onChange) {
    const box = document.getElementById(containerId);
    for (const item of items) {
      const label = document.createElement("label");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = true;
      input.addEventListener("change", () => { onChange(item, input.checked); render(); });
      label.append(input, " " + item);
      box.appendChild(label);
    }
  }

  checkboxes("vars", varNames, (v, on) => (on ? state.keepVars.add(v) : state.keepVars.delete(v)));
  checkboxes("actions", actions, (a, on) => (on ? state.hiddenActions.delete(a) : state.hiddenActions.add(a)));
  document.getElementById("fit").addEventListener("click", () => cy.fit(undefined, 30));
  if (data.note) document.getElementById("note").textContent = data.note;
  render();
})();
