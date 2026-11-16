// Merge Endor's Cortex Code hooks into a user's hooks.json (macOS engine).
//
// Usage: osascript -l JavaScript cortexcode-merge.js EXISTING RENDERED OUT
//
// JXA is the JSON parser that every Mac has, so the runner needs no jq and no
// python3 (which is only a Command Line Tools stub on a stock Mac).
// cortexcode-merge.py is the Linux engine and must give the same result. Run
// through cortexcode-merge.sh, which picks the engine. mergeCortexHooks is plain
// JavaScript so that the test suite can run it under node.
//
// A hook whose command matches "ai-audit cortexcode" is Endor's. Every other
// hook, matcher group, event, and top-level key is the user's and is kept in
// place. Endor's current groups go after the user's in each event. When nothing
// of the user's is left, OUT is RENDERED byte for byte.
//
// A throw makes osascript exit non-zero before OUT is written. The caller must
// then leave the user's file as it is.

var ENDOR = /ai-audit[ \t]+cortexcode(?![A-Za-z0-9_])/;

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function parse(text, label) {
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new Error(label + ' is not valid JSON: ' + e.message);
  }
}

function isEndor(hook) {
  return isObject(hook) && typeof hook.command === 'string' && ENDOR.test(hook.command);
}

function stripEndor(groups) {
  var keep = [];
  groups.forEach(function (g) {
    if (!isObject(g) || !Array.isArray(g.hooks)) {
      keep.push(g);
      return;
    }
    var inner = g.hooks.filter(function (h) { return !isEndor(h); });
    if (inner.length === g.hooks.length) {
      keep.push(g);
    } else if (inner.length > 0) {
      var copy = {};
      Object.keys(g).forEach(function (k) { copy[k] = k === 'hooks' ? inner : g[k]; });
      keep.push(copy);
    }
  });
  return keep;
}

function mergeCortexHooks(existingText, renderedText) {
  var existing = parse(existingText, 'the existing file');
  var rendered = parse(renderedText, 'the rendered file');
  if (!isObject(existing)) throw new Error('the existing file is not a JSON object');
  var hooks = 'hooks' in existing ? existing.hooks : {};
  if (!isObject(hooks)) throw new Error('the existing "hooks" is not a JSON object');

  var foreign = {};
  Object.keys(hooks).forEach(function (event) {
    var groups = hooks[event];
    if (!Array.isArray(groups)) throw new Error('the existing "hooks.' + event + '" is not a JSON array');
    var keep = stripEndor(groups);
    // An event left empty is not the user's when it is one of Endor's events:
    // either the strip emptied it, or Endor's groups go into it anyway.
    // Dropping it puts Endor's groups at the same place on every run, so a
    // second run gives the same bytes. Any other empty event is the user's.
    var endorEvent = Object.prototype.hasOwnProperty.call(rendered.hooks, event);
    if (keep.length > 0 || (groups.length === 0 && !endorEvent)) foreign[event] = keep;
  });

  var others = Object.keys(existing).filter(function (k) { return k !== 'hooks'; });
  if (Object.keys(foreign).length === 0 && others.length === 0) return renderedText;

  Object.keys(rendered.hooks).forEach(function (event) {
    foreign[event] = (foreign[event] || []).concat(rendered.hooks[event]);
  });
  var merged = {};
  Object.keys(existing).forEach(function (k) { merged[k] = k === 'hooks' ? foreign : existing[k]; });
  if (!('hooks' in merged)) merged.hooks = foreign;
  return JSON.stringify(merged, null, 2) + '\n';
}

function run(argv) {
  ObjC.import('Foundation');
  function read(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    if (s.isNil()) throw new Error('cannot read ' + path + ' as UTF-8');
    return s.js;
  }
  var out = mergeCortexHooks(read(argv[0]), read(argv[1]));
  if (!$(out).writeToFileAtomicallyEncodingError(argv[2], true, $.NSUTF8StringEncoding, null)) {
    throw new Error('cannot write ' + argv[2]);
  }
}
