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
assert.equal(failures, 0);
console.log('Frontend-Regressionen bestanden');
