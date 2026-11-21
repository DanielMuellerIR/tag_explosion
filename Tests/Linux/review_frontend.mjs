// Führt die produktiven Editor-Callbacks mit einem kleinen DOM-Double aus.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../../Linux/frontend/app.js', import.meta.url), 'utf8');
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.events = {}; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  addEventListener(name, fn) { this.events[name] = fn; }
  setAttribute(name, value) { this[name] = value; }
  removeAttribute(name) { delete this[name]; }
  querySelector() { return new Element('strong'); }
}
const elements = new Map();
const context = vm.createContext({
  Node: Element, structuredClone, console,
  document: { createElement: tag => new Element(tag), createTextNode: text => text },
});
function functionText(name) {
  const start = source.indexOf(`function ${name}(`);
  const end = source.indexOf('\n}', start) + 2;
  return source.slice(start, end);
}
for (const name of ['node', 'button', 'editValue']) vm.runInContext(functionText(name), context);
Object.assign(context, {
  t: text => text, label: text => text, showError: error => { throw error; },
  fieldGrid: () => new Element('grid'),
  $: id => { if (!elements.has(id)) elements.set(id, new Element(id)); return elements.get(id); },
});
function descendants(element) {
  return [element, ...(element.children || []).flatMap(child => typeof child === 'object' ? descendants(child) : [])];
}
let failures = 0;
for (const [key, expected] of [['chapters', [{ title: '', start: 0, end: 0 }]], ['syncedLyrics', [{ time: 0, text: '' }]]]) {
  try {
    let changed;
    const editor = context.editValue([], value => { changed = value; }, key);
    descendants(editor).find(e => e.tag === 'button' && e.children.includes('Hinzufügen')).events.click({});
    assert.deepEqual(JSON.parse(JSON.stringify(changed)), expected);
  } catch (error) { failures++; console.error(key, error.message); }
}
vm.runInContext('async ' + functionText('renderBatch'), context);
for (const [kind, fields, key, raw, expected] of [
  ['sidecar', {rating: '', title: '', genres: []}, 'rating', '7.50', '7.50'],
  ['sidecar', {rating: '8'}, 'rating', '', ''],
  ['sidecar', {genres: []}, 'genres', 'A; B', ['A', 'B']],
  ['ebook', {title: ''}, 'title', 'Test', 'Test'],
]) {
  try {
    const changes = {};
    Object.assign(context, {
      state: {selection: ['a', 'b'], entries: [{path:'a', kind}, {path:'b', kind}]},
      batchChanges: changes,
      request: async () => ({first: {kind, fields}, common: fields, mixed: [], supportedFields: Object.keys(fields), readOnly: false}),
      section: (_title, ...items) => items, rules() {}, filename() {}, check() {}, toolsMenu() {}, enqueue() {},
    });
    await context.renderBatch();
    const input = descendants(elements.get('editor')).find(e => e.tag === 'input' && e['aria-label'] === key);
    input.events.input({target: {value: raw}});
    assert.deepEqual(JSON.parse(JSON.stringify(changes[key])), expected);
  } catch (error) { failures++; console.error(kind, key, error.message); }
}
vm.runInContext('async ' + functionText('discardEdits'), context);
function deferred() {
  let resolve, reject;
  const promise = new Promise((onResolve, onReject) => { resolve = onResolve; reject = onReject; });
  return { promise, resolve, reject };
}
for (const reject of [false, true]) {
  const next = {selection: ['a']};
  const reply = deferred();
  const received = deferred();
  let rendered = false;
  Object.assign(context, {
    debounce: null, clearTimeout() {}, pending: true, batchChanges: {title: 'Entwurf'},
    state: {selection: ['a']}, modal: async () => true, enqueue: callback => callback(),
    request: method => { assert.equal(method, 'revert'); received.resolve(); return reply.promise; },
    updateState: value => assert.equal(value, next),
    renderSelection: () => { rendered = true; },
  });
  const started = context.discardEdits();
  await received.promise;
  const editor = context.$('editor');
  assert.equal(editor.inert, true);
  assert.equal(editor['aria-busy'], 'true');
  if (reject) {
    reply.reject(new Error('Worker offline'));
    await assert.rejects(started, /Worker offline/);
  } else {
    reply.resolve(next);
    await started;
  }
  assert.equal(editor.inert, false);
  assert.equal(editor['aria-busy'], undefined);
  assert.equal(context.pending, reject);
  assert.equal(context.batchChanges.title, reject ? 'Entwurf' : undefined);
  assert.equal(rendered, !reject);
}
{
  const editor = fs.readFileSync(new URL('../../Linux/frontend/rules.js', import.meta.url), 'utf8');
  vm.runInContext(editor.replace('export async function', 'async function'), context);
  const ready = deferred();
  const modalResult = deferred();
  let controls;
  let applied = false;
  const edit = context.editRules({
    node: context.node, button: context.button, t: value => value,
    modal: (_title, content, actions) => {
      controls = { content, apply: actions[1].control };
      ready.resolve();
      return modalResult.promise;
    },
    enqueue: action => action(), flush: async () => {}, editorContext: () => 'one',
    dismiss: () => modalResult.resolve(), act: async () => { applied = true; },
    request: async (method, params) => {
      if (method === 'rulesSchema') return { templates: [
        { id: 'a', title: 'a', document: { version: 1, rules: [], _comment: 'first' } },
        { id: 'b', title: 'b', document: { version: 1, rules: [], _comment: 'second' } },
      ] };
      assert.equal(method, 'rulesPreview');
      assert.equal(params.confirmable, true);
      return { token: 'preview-first', plans: [{ path: 'a.mp3', changes: [{ field: 'TITLE', old: 'old', new: 'first' }] }] };
    },
  });
  await ready.promise;
  const inspect = descendants(controls.content).find(e => e.tag === 'button' && e.children.includes('Vorschau'));
  const template = descendants(controls.content).find(e => e.tag === 'select' && e['aria-label'] === 'Vorlage');
  assert.equal(controls.apply.disabled, true);
  inspect.events.click({});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(controls.apply.disabled, false);
  template.events.change({target: {value: 'b'}});
  assert.equal(controls.apply.disabled, true);
  assert.equal(descendants(controls.content).some(e => e.tag === 'table'), false);
  controls.apply.events.click({});
  modalResult.resolve();
  await edit;
  assert.equal(applied, false);
}
assert.equal(failures, 0);
console.log('Frontend-Regressionen bestanden');
