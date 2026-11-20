// Reads a WoW SavedVariables file (plain Lua table literals: NAME = { ... }) into JS objects.
// A parser, not a Lua interpreter: nothing in the file is executed.
//   parseSavedVariables(text) -> { NAME: value, ... }
// Tables with only keys 1..n become arrays; others become objects.

function parseSavedVariables(text) {
  let i = 0;
  const n = text.length;
  const fail = (msg) => { throw new Error(`SavedVariables parse error at ${i}: ${msg}`); };

  function skip() {
    for (;;) {
      while (i < n && /\s/.test(text[i])) i++;
      if (text.startsWith("--", i)) {
        const long = text.slice(i + 2).match(/^\[(=*)\[/);
        if (long) {
          const close = "]" + long[1] + "]";
          const end = text.indexOf(close, i);
          i = end < 0 ? n : end + close.length;
        } else {
          while (i < n && text[i] !== "\n") i++;
        }
        continue;
      }
      return;
    }
  }

  function str() {
    const q = text[i++];
    let out = "";
    while (i < n && text[i] !== q) {
      let c = text[i++];
      if (c === "\\") {
        c = text[i++];
        if (c === "n") out += "\n";
        else if (c === "t") out += "\t";
        else if (c === "r") out += "\r";
        else if (c === "a") out += "\x07";
        else if (c === "b") out += "\b";
        else if (c === "f") out += "\f";
        else if (c === "v") out += "\v";
        else if (c === "\n") out += "\n";
        else if (/\d/.test(c)) {
          let d = c;
          while (d.length < 3 && /\d/.test(text[i])) d += text[i++];
          out += String.fromCharCode(Number(d));
        } else out += c;
      } else out += c;
    }
    i++;
    return out;
  }

  function longStr() {
    const m = text.slice(i).match(/^\[(=*)\[\n?/);
    const close = "]" + m[1] + "]";
    const start = i + m[0].length;
    const end = text.indexOf(close, start);
    if (end < 0) fail("unclosed long string");
    i = end + close.length;
    return text.slice(start, end);
  }

  function value() {
    skip();
    const c = text[i];
    if (c === "{") return table();
    if (c === '"' || c === "'") return str();
    if (c === "[" && /^\[=*\[/.test(text.slice(i, i + 10))) return longStr();
    const m = text.slice(i, i + 64).match(/^(-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|-?inf|-?nan|true|false|nil)/);
    if (!m) fail("unexpected " + JSON.stringify(text.slice(i, i + 20)));
    i += m[0].length;
    const w = m[0];
    if (w === "true") return true;
    if (w === "false") return false;
    if (w === "nil") return null;
    if (/inf$/.test(w)) return w.startsWith("-") ? -Infinity : Infinity;
    if (/nan$/.test(w)) return NaN;
    return Number(w);
  }

  function table() {
    i++; // {
    const entries = [];
    let next = 1;
    for (;;) {
      skip();
      if (text[i] === "}") { i++; break; }
      let key;
      if (text[i] === "[" && !/^\[=*\[/.test(text.slice(i, i + 10))) {
        i++;
        key = value();
        skip();
        if (text[i] !== "]") fail("expected ]");
        i++;
        skip();
        if (text[i] !== "=") fail("expected =");
        i++;
        entries.push([key, value()]);
      } else {
        const id = text.slice(i).match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)/);
        if (id) {
          i += id[0].length;
          entries.push([id[1], value()]);
        } else {
          entries.push([next++, value()]);
        }
      }
      skip();
      if (text[i] === "," || text[i] === ";") i++;
    }
    const isArray = entries.every(([k], idx) => k === idx + 1);
    if (isArray) return entries.map(([, v]) => v);
    const obj = {};
    for (const [k, v] of entries) if (v !== null) obj[k] = v;
    return obj;
  }

  const out = {};
  for (;;) {
    skip();
    if (i >= n) break;
    const id = text.slice(i).match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    if (!id) fail("expected NAME =");
    i += id[0].length;
    out[id[1]] = value();
  }
  return out;
}

module.exports = { parseSavedVariables };
