import { editRules } from "./rules.js";
import { labels, translate, setLanguage } from "./translations.js";
const tauri = window.__TAURI__;
const invoke = tauri.core.invoke;
const nativeWindow = tauri.window.getCurrentWindow();
const $ = (id) => document.getElementById(id);
const language = await invoke("system_locale");
setLanguage(language);
const t = translate;
let state = { revision: 0, entries: [], selection: [], total: 0 };
let draft = null,
  activeTab = "tags",
  coverIndex = 0,
  pending = false,
  generation = 0;
let chain = Promise.resolve(),
  debounce = null,
  closingDecision = false,
  operations = 0,
  polling = false,
  technicalLoading = false;
let preferences = {},
  lastSelected = null,
  batchChanges = {};

function node(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (name.startsWith("on")) element.addEventListener(name.slice(2), value);
    else if (name === "class") element.className = value;
    else if (name === "text") element.textContent = value;
    else if (name === "checked") element.checked = value;
    else if (name === "selected") element.selected = value;
    else if (name === "hidden") element.hidden = value;
    else if (name === "value") element.value = value ?? "";
    else if (name === "disabled") element.disabled = value;
    else element.setAttribute(name, String(value));
  }
  for (const child of children.flat(Infinity))
    if (child !== null && child !== undefined)
      element.append(
        child instanceof Node ? child : document.createTextNode(String(child)),
      );
  return element;
}
function button(text, action, attributes = {}) {
  return node(
    "button",
    {
      type: "button",
      onclick: (event) => {
        try {
          Promise.resolve(action(event)).catch(showError);
        } catch (error) {
          showError(error);
        }
      },
      ...attributes,
    },
    t(text),
  );
}
function enqueue(action) {
  const operation = chain.then(action);
  chain = operation.catch((error) => {
    showError(error);
  });
  return operation;
}
async function request(method, params = {}) {
  return invoke("media", {
    method,
    params: { ...params, revision: state.revision },
  });
}
function status(message) {
  $("status").textContent = message;
}
function updateState(next) {
  state = next;
  renderList();
  $("save").disabled =
    !state.selection.some(
      (path) => state.entries.find((entry) => entry.path === path)?.dirty,
    ) && !pending;
  $("save-all").disabled = !state.dirty && !pending;
  $("check").disabled = !state.total;
  $("cancel").hidden = !state.busy && !state.loading && !operations;
  $("selection-count").textContent =
    `${state.selection.length} ${t("ausgewählt")} · ${state.hiddenSelection || 0} ${t("ausgeblendet")}`;
  status(
    state.loading
      ? `${t("Lade Dateien …")} ${state.completed}/${state.count}`
      : `${state.total} ${t("Dateien")} · ${state.selection.length} ${t("ausgewählt")}`,
  );
  if (!state.total) document.body.classList.add("sidebar-hidden");
}
async function flush() {
  clearTimeout(debounce);
  if (Object.keys(batchChanges).length) {
    const changes = batchChanges;
    batchChanges = {};
    try {
      updateState(await request("batchEdit", { changes }));
    } catch (error) {
      batchChanges = { ...changes, ...batchChanges };
      throw error;
    }
  }
  if (!pending || !draft) return;
  const current = generation;
  const values = structuredClone(draft);
  updateState(await request("edit", { path: values.path, values }));
  if (generation === current) pending = false;
}
function edited() {
  pending = true;
  generation++;
  $("save").disabled = false;
  $("save-all").disabled = false;
  status(t("Ungespeicherte Änderungen"));
  clearTimeout(debounce);
  debounce = setTimeout(() => enqueue(flush), 450);
}
async function act(method, params = {}, reload = true) {
  return enqueue(async () => {
    await flush();
    operations++;
    $("cancel").hidden = false;
    let result;
    try {
      result = await request(method, params);
    } finally {
      operations--;
    }
    if (result && Array.isArray(result.entries)) updateState(result);
    await decisions();
    if (reload) await renderSelection();
    return result;
  });
}
async function refresh() {
  updateState(await request("state"));
}
setInterval(async () => {
  if (!operations || polling) return;
  polling = true;
  try {
    const next = await request("state");
    if (operations) updateState(next);
  } catch (error) {
    status(String(error));
  } finally {
    polling = false;
  }
}, 350);
async function openFiles(paths) {
  if (!paths?.length) return;
  document.body.classList.remove("sidebar-hidden");
  await act("open", { paths });
}
async function choose(purpose = "open", suggested) {
  return invoke("choose", { purpose, suggested: suggested ?? null });
}
let currentModal = null;
function dismissDialog() {
  if (currentModal) currentModal(null);
}
function modal(title, content, actions = [{ title: "Schließen" }]) {
  dismissDialog();
  return new Promise((resolve) => {
    const dialog = $("dialog");
    const finish = (value) => {
      dialog.removeEventListener("cancel", cancelled);
      if (currentModal === finish) currentModal = null;
      dialog.close();
      resolve(value);
    };
    const cancelled = (event) => {
      event.preventDefault();
      finish(null);
    };
    currentModal = finish;
    $("dialog-title").textContent = t(title);
    $("dialog-content").replaceChildren(
      content instanceof Node ? content : node("p", {}, String(content)),
    );
    $("dialog-actions").replaceChildren(
      ...actions.map((action, index) =>
        button(action.title, () => finish(action.value ?? index), {
          class: action.primary ? "primary" : action.danger ? "danger" : "",
        }),
      ),
    );
    dialog.addEventListener("cancel", cancelled);
    dialog.showModal();
    if (!$('dialog-content').querySelector('input, textarea, select'))
      $('dialog-actions').querySelector('.primary, button')?.focus({ preventScroll: true });
    $('dialog-content').scrollTop = 0;
  });
}
function showError(error) {
  status(String(error));
  return modal("Hinweis", String(error));
}
async function decisions() {
  while (state.conflict || state.externalImport || state.staleWrite) {
    let params;
    if (state.conflict) {
      const choice = await modal(state.conflict.title, state.conflict.message, [
        { title: "Abbrechen", value: "cancel" },
        { title: "Verwerfen", value: "discard", danger: true },
        { title: "Speichern", value: "save", primary: true },
      ]);
      params = { dirty: choice ?? "cancel" };
    } else if (state.externalImport) {
      const choice = await modal("Externe Importziele", state.externalImport, [
        { title: "Abbrechen", value: false },
        { title: "Alle Ziele freigeben", value: true, danger: true },
      ]);
      params = { external: choice === true };
    } else {
      const choice = await modal(
        "Datei wurde außerhalb geändert",
        `${state.staleWrite}\n\n${t("Die Datei wurde seit dem Öffnen geändert. Speichern überschreibt diese Änderung; der jetzige Stand wird vorher im Papierkorb gesichert, sofern der abgesicherte Modus aktiv ist.")}`,
        [
          { title: "Abbrechen", value: false },
          { title: "Trotzdem speichern", value: true, danger: true },
        ],
      );
      params = { overwrite: choice === true };
    }
    updateState(await request("resolve", params));
  }
  if (state.alert) {
    const text = state.alert;
    updateState(await request("clearAlert"));
    await modal("Hinweis", text);
  }
}
function renderList() {
  const list = $("file-list"),
    top = list.scrollTop;
  list.replaceChildren(
    ...state.entries.map((entry) =>
      node(
        "div",
        {
          role: "option",
          "aria-selected": state.selection.includes(entry.path),
          "data-path": entry.path,
          class: `file-row${entry.dirty ? " dirty" : ""}${entry.error ? " error" : ""}`,
          title: entry.path,
          onclick: (event) => selectEntry(entry.path, event),
          oncontextmenu: (event) => {
            event.preventDefault();
            selectEntry(entry.path, {}).then(() => toolsMenu());
          },
        },
        node("strong", {}, entry.title),
        node("small", {}, entry.error || entry.subtitle || entry.name),
      ),
    ),
  );
  list.scrollTop = top;
}
async function selectEntry(path, event = {}) {
  if (technicalLoading) await request("cancel", { operation: "info" });
  return enqueue(async () => {
    await flush();
    let selection;
    if (event.shiftKey && lastSelected) {
      const a = state.entries.findIndex((entry) => entry.path === lastSelected),
        b = state.entries.findIndex((entry) => entry.path === path);
      selection = state.entries
        .slice(Math.min(a, b), Math.max(a, b) + 1)
        .map((entry) => entry.path);
    } else if (event.ctrlKey || event.metaKey)
      selection = state.selection.includes(path)
        ? state.selection.filter((value) => value !== path)
        : [...state.selection, path];
    else selection = [path];
    lastSelected = path;
    updateState(await request("select", { paths: selection }));
    activeTab = "tags";
    coverIndex = 0;
    await renderSelection();
  });
}
function section(title, content) {
  return [
    node("h3", {}, t(title)),
    node("section", { class: "group" }, content),
  ];
}
function label(key) {
  return t(labels[key] || key.replace(/([a-z])([A-Z])/g, "$1 $2"));
}
function fieldGrid(fields, onChange, disabled = false) {
  const grid = node("div", { class: "fields" });
  const order =
    draft?.kind === "image"
      ? [
          "title",
          "description",
          "keywords",
          "creator",
          "copyright",
          "dateTimeOriginal",
          "rating",
          "gpsLatitude",
          "gpsLongitude",
        ]
      : draft?.kind === "ebook"
        ? [
            "title",
            "authors",
            "series",
            "seriesIndex",
            "isbn",
            "publisher",
            "date",
            "language",
            "subjects",
            "description",
          ]
        : [
            "title",
            "originalTitle",
            "sortTitle",
            "showTitle",
            "authors",
            "author",
            "performer",
            "subject",
            "description",
            "keywords",
            "year",
            "premiered",
            "plot",
            "outline",
            "tagline",
            "genres",
            "tags",
            "studio",
            "directors",
            "credits",
            "rating",
            "userRating",
            "mpaa",
            "runtime",
            "season",
            "episode",
            "publisher",
            "language",
            "category",
            "created",
            "modified",
            "custom",
          ];
  const rank = (key) =>
    order.includes(key) ? order.indexOf(key) : order.length;
  for (const [key, value] of Object.entries(fields).sort(
    (a, b) => rank(a[0]) - rank(b[0]),
  )) {
    const id = `field-${key}-${Math.random().toString(36).slice(2)}`;
    const editor = editValue(
      value,
      (next) => onChange(key, next),
      key,
      disabled === true || (Array.isArray(disabled) && !disabled.includes(key)),
    );
    const first = editor.matches("input,textarea,select")
      ? editor
      : editor.querySelector("input,textarea,select");
    if (first) first.id = id;
    grid.append(
      node(
        "label",
        { for: id },
        label(key),
        draft?.kind === "image" &&
          draft.sidecarFields?.includes(key.startsWith("gps") ? "gps" : key)
          ? node("small", { class: "source-badge" }, t("Sidecar"))
          : null,
      ),
      draft?.kind === "image" &&
        ["title", "description", "keywords", "creator", "copyright"].includes(
          key,
        )
        ? node(
            "div",
            { class: "field-value" },
            editor,
            button("▾", () => copyField(key), {
              title: t("Aus anderem Feld kopieren"),
            }),
          )
        : editor,
    );
  }
  return grid;
}
function editValue(value, changed, key, disabled = false) {
  if (key === "rating" && draft?.kind === "image") {
    return node(
      "select",
      {
        disabled,
        "aria-label": label(key),
        onchange: (event) =>
          changed(
            event.target.value === "" ? null : Number(event.target.value),
          ),
      },
      ...draft.ratingOptions.map((option) =>
        node(
          "option",
          { value: option.value ?? "", selected: value === option.value },
          option.label,
        ),
      ),
    );
  }
  if (Array.isArray(value)) {
    const result = node("div", { class: "multiple-values" });
    function rows() {
      result.replaceChildren(
        ...value.map((item, index) =>
          node(
            "div",
            { class: "row" },
            item && typeof item === "object"
              ? fieldGrid(
                  item,
                  (field, next) => {
                    value[index][field] = next;
                    changed(value);
                  },
                  disabled,
                )
              : node(
                  /lyrics|description|comment|plot/i.test(key)
                    ? "textarea"
                    : "input",
                  {
                    value: item,
                    disabled,
                    "aria-label": label(key),
                    oninput: (event) => {
                      value[index] = event.target.value;
                      changed(value);
                    },
                  },
                ),
            button(
              "Entfernen",
              () => {
                value.splice(index, 1);
                changed(value);
                rows();
              },
              { disabled, "aria-label": `${label(key)} ${t("entfernen")}` },
            ),
          ),
        ),
        button(
          "Hinzufügen",
          () => {
            value.push(
              value[0] && typeof value[0] === "object"
                ? Object.fromEntries(
                    Object.entries(value[0]).map(([field, item]) => [
                      field,
                      typeof item === "number"
                        ? 0
                        : Array.isArray(item)
                          ? []
                          : "",
                    ]),
                  )
                : structuredClone(
                    {
                      chapters: {
                        title: "",
                        start: 0,
                        end: 0,
                      },
                      syncedLyrics: { time: 0, text: "" },
                      custom: { key: "", value: "" },
                      entries: { title: "", performer: "" },
                      actors: { name: "", role: "" },
                    }[key] ?? "",
                  ),
            );
            changed(value);
            rows();
          },
          { disabled },
        ),
      );
    }
    rows();
    return result;
  }
  if (value && typeof value === "object")
    return fieldGrid(
      value,
      (field, next) => {
        value[field] = next;
        changed(value);
      },
      disabled,
    );
  const multiline = /description|comment|lyrics|plot|outline|text/i.test(key);
  const control = node(multiline ? "textarea" : "input", {
    value: value ?? "",
    disabled,
    "aria-label": label(key),
    oninput: (event) => {
      const raw = event.target.value;
      changed(
        typeof value === "number" || (key === "rating" && value === null)
          ? raw === ""
            ? null
            : Number(raw)
          : raw,
      );
    },
  });
  if (!multiline)
    control.type =
      typeof value === "number" || (key === "rating" && value === null)
        ? "number"
        : "text";
  return control;
}
const mainTags = [
  "TITLE",
  "ARTIST",
  "ALBUM",
  "ALBUMARTIST",
  "GENRE",
  "DATE",
  "TRACKNUMBER",
  "DISCNUMBER",
  "COMPOSER",
  "COMMENT",
];
function audioFields(keys, container = draft, single = false) {
  if (!single) {
    const fields = Object.fromEntries(
      keys.map((key) => [
        key,
        container.properties
          .filter((property) => property.key === key)
          .map((property) => property.value),
      ]),
    );
    return fieldGrid(
      fields,
      (key, values) => setProperties(container, key, values),
      container.readOnly,
    );
  }
  const grid = node("div", { class: "fields" });
  for (const key of keys) {
    const control = node("input", {
      value:
        container.properties.find((property) => property.key === key)?.value ||
        "",
      disabled:
        container.readOnly ||
        (container.writableKeys && !container.writableKeys.includes(key)),
      "aria-label": label(key),
      oninput: (event) => setProperties(container, key, [event.target.value]),
    });
    grid.append(
      node("label", {}, label(key)),
      node(
        "div",
        { class: "field-value" },
        control,
        button("▾", () => copyField(key), {
          title: t("Aus anderem Feld kopieren"),
          "aria-label": `${label(key)}: ${t("Aus anderem Feld kopieren")}`,
        }),
      ),
    );
  }
  return grid;
}
function setProperties(container, key, values) {
  const index = container.properties.findIndex(
    (property) => property.key === key,
  );
  container.properties = container.properties.filter(
    (property) => property.key !== key,
  );
  container.properties.splice(
    index < 0 ? container.properties.length : index,
    0,
    ...values.filter((value) => value !== "").map((value) => ({ key, value })),
  );
  edited();
}
async function copyField(target, keys = null) {
  await enqueue(flush);
  const image =
    draft?.kind === "image" ||
    state.entries.find((entry) => entry.path === state.selection[0])?.kind ===
      "image";
  if (!keys)
    keys = image
      ? [
          ...new Set(
            Object.values(await request("rawImageTags")).flatMap((tags) =>
              Object.keys(tags),
            ),
          ),
        ].sort()
      : [...new Set(draft.properties.map((property) => property.key))];
  const list = node("div", { class: "rule-list" }),
    search = node("input", {
      type: "search",
      class: "wide",
      placeholder: t("Filtern …"),
    });
  const draw = () =>
    list.replaceChildren(
      ...keys
        .filter(
          (key) =>
            key !== target &&
            key.toLocaleLowerCase().includes(search.value.toLocaleLowerCase()),
        )
        .map((key) =>
          button(image ? key : label(key), async () => {
            dismissDialog();
            await act("copyField", { target, source: key });
          }),
        ),
    );
  search.addEventListener("input", draw);
  draw();
  await modal("Aus anderem Feld kopieren", node("div", {}, search, list));
}
async function renderSelection() {
  if (pending || Object.keys(batchChanges).length) return;
  draft = null;
  $("tabs").replaceChildren();
  if (!state.selection.length) {
    renderEmpty();
    return;
  }
  if (state.selection.length > 1) {
    await renderBatch();
    return;
  }
  draft = await request("entry", { path: state.selection[0] });
  $("window-title").querySelector("strong").textContent = draft.title;
  $("window-subtitle").textContent = draft.path.split("/").pop();
  const tabs = [
    ["tags", draft.kind === "invoice" ? "Rechnung" : "Tags"],
    ["info", "Technik"],
  ];
  if (draft.kind === "image") tabs.splice(1, 0, ["metadata", "Alle Metadaten"]);
  if (draft.kind === "ebook" && draft.path.toLowerCase().endsWith(".pdf"))
    tabs.splice(1, 0, ["invoice", "E-Rechnung"]);
  if (!tabs.some(([key]) => key === activeTab)) activeTab = "tags";
  for (const [key, title] of tabs)
    $("tabs").append(
      button(
        title,
        async () => {
          if (technicalLoading) await request("cancel", { operation: "info" });
          return enqueue(async () => {
            await flush();
            activeTab = key;
            await renderSelection();
          });
        },
        { role: "tab", "aria-selected": activeTab === key },
      ),
    );
  const content = node("div", { class: "editor-content" });
  $("editor").replaceChildren(content);
  if (activeTab === "info") {
    await technical(content);
    return;
  }
  if (activeTab === "metadata") {
    await metadata(content);
    return;
  }
  if (activeTab === "invoice" || draft.kind === "invoice") {
    await invoice(content);
    return;
  }
  content.append(await hero());
  if (draft.readOnly)
    content.append(
      node("p", { class: "notice" }, t("Diese Datei ist nur lesbar.")),
    );
  switch (draft.kind) {
    case "audio":
      renderAudio(content);
      break;
    case "image":
    case "ebook":
    case "document":
    case "sidecar":
      if (draft.kind === "image" && !("rating" in draft.fields))
        draft.fields.rating = null;
      content.append(
        ...section(
          "Tags",
          fieldGrid(
            draft.fields,
            (key, value) => {
              draft.fields[key] = value;
              edited();
            },
            draft.readOnly
              ? true
              : draft.kind === "document"
                ? [...draft.supportedFields, "custom"]
                : draft.subkind === "subtitle"
                  ? draft.supportedFields
                  : draft.kind === "ebook" && !draft.supportsSeries
                    ? Object.keys(draft.fields).filter(
                        (key) => !["series", "seriesIndex"].includes(key),
                      )
                    : false,
          ),
        ),
      );
      if (draft.writeDestination)
        content.append(node("p", { class: "notice" }, draft.writeDestination));
      if (draft.sidecar)
        content.append(
          node(
            "p",
            { class: "notice" },
            `${t("XMP-Sidecar")}: ${draft.sidecar}`,
          ),
        );
      if (draft.info)
        content.append(...section("Informationen", readonly(draft.info)));
      if (draft.subkind === "subtitle")
        content.append(button("Untertitel verschieben …", shiftSubtitle));
      break;
    case "playlist":
      renderPlaylist(content);
      break;
  }
}
async function hero() {
  const detail = node(
    "div",
    { class: "hero-info" },
    node("h1", {}, draft.path.split("/").pop()),
    node("p", { class: "path" }, draft.path),
  );
  if (draft.audio)
    detail.append(
      node(
        "p",
        { class: "technical" },
        `${(draft.audio.lengthMilliseconds / 1000).toFixed(1)} s · ${draft.audio.bitrateKbps} kbps · ${draft.audio.sampleRateHz} Hz · ${draft.audio.channels} ${t("Kanäle")}`,
      ),
    );
  const tools = node("div", { class: "row" });
  if (draft.supportsFilenamePatterns)
    tools.append(button("Dateiname …", filename));
  if (draft.kind === "audio")
    tools.append(button("Online nachschlagen …", onlineLookup));
  tools.append(
    button("Versionen …", history),
    button("Werkzeuge …", toolsMenu),
  );
  detail.append(tools);
  const result = node("div", { class: "hero" });
  if (
    draft.kind === "audio" ||
    (draft.kind === "ebook" && draft.supportsCover) ||
    (draft.kind === "document" && draft.hasCover)
  ) {
    const cover = node(
      "div",
      {
        class: "cover",
        id: "cover-well",
        tabindex: "0",
        role: "button",
        "aria-label": t("Cover auswählen"),
        onclick: chooseCover,
        onkeydown: (event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            chooseCover();
          }
        },
      },
      node("span", { class: "cover-symbol" }, "▧"),
      node("span", {}, t("Cover hierher ziehen")),
    );
    const block = node("div", { class: "cover-block" }, cover);
    if (draft.kind !== "document")
      block.append(
        node(
          "div",
          { class: "row" },
          button("Auswählen …", chooseCover),
          button("Werkzeuge …", coverTools),
        ),
      );
    if (draft.artworks?.length > 1) {
      if (coverIndex >= draft.artworks.length) coverIndex = 0;
      block.append(
        node(
          "select",
          {
            id: "cover-select",
            "aria-label": t("Cover"),
            onchange: (event) => {
              coverIndex = Number(event.target.value);
              renderSelection().catch(showError);
            },
          },
          ...draft.artworks.map((art, index) =>
            node(
              "option",
              { value: index, selected: index === coverIndex },
              `${index + 1}: ${art.pictureType || t("Cover")} ${art.description}`,
            ),
          ),
        ),
      );
    }
    result.append(block);
    const path = draft.path;
    request("cover", { path, index: coverIndex })
      .then((data) => {
        if (data && draft?.path === path && cover.isConnected)
          cover.replaceChildren(
            node("img", {
              src: `data:${draft.artworks?.[coverIndex]?.mimeType || "image/png"};base64,${data}`,
              alt: t("Cover"),
            }),
          );
      })
      .catch(() => {});
  }
  if (draft.kind === "image") {
    const preview = node(
      "div",
      { class: "cover image-preview", "aria-label": t("Bildvorschau") },
      "▧",
    );
    result.append(preview);
    const path = draft.path;
    request("imagePreview", { path })
      .then((value) => {
        if (value && preview.isConnected && draft?.path === path)
          preview.replaceChildren(
            node("img", {
              src: `data:${value.mimeType};base64,${value.data}`,
              alt: t("Bildvorschau"),
            }),
          );
      })
      .catch(() => {});
  }
  result.append(detail);
  return result;
}
function renderAudio(content) {
  content.append(...section("Tags", audioFields(mainTags, draft, true)));
  const dedicated = [
    ...(draft.supportsLyrics ? ["LYRICS", "UNSYNCEDLYRICS"] : []),
    ...(draft.supportsLoudness ? draft.loudnessKeys : []),
    ...(draft.supportsPodcast ? draft.podcastKeys : []),
  ];
  const others = [
    ...new Set(draft.properties.map((property) => property.key)),
  ].filter((key) => !mainTags.includes(key) && !dedicated.includes(key));
  const extra = node("div", {}, audioFields(others));
  const key = node("input", {
    placeholder: t("Neuer Feldname"),
    "aria-label": t("Neuer Feldname"),
  });
  extra.append(
    node(
      "div",
      { class: "row spaced" },
      key,
      button("Feld hinzufügen", () => {
        const name = key.value.trim().toUpperCase();
        if (
          name &&
          !draft.properties.some((property) => property.key === name)
        ) {
          draft.properties.push({ key: name, value: "" });
          edited();
          content.replaceChildren();
          hero().then((value) => {
            content.append(value);
            renderAudio(content);
          });
        }
      }),
    ),
  );
  content.append(...section("Weitere Felder", extra));
  if (draft.supportsLyrics && !draft.readOnly) {
    content.append(
      ...section("Lyrics", audioFields(["LYRICS", "UNSYNCEDLYRICS"])),
    );
    const fields = {
      ...(draft.supportsSyncedLyrics
        ? { lyricsLanguage: draft.lyricsLanguage }
        : {}),
      syncedLyrics: draft.syncedLyrics,
    };
    const grid = fieldGrid(
      fields,
      (key, value) => {
        draft[key] = value;
        edited();
      },
      draft.readOnly,
    );
    content.append(
      ...section(
        "Synchronisierte Liedtexte",
        node("div", {}, grid, interchange("LRC")),
      ),
    );
  }
  if (draft.supportsLoudness && !draft.readOnly)
    content.append(
      ...section("Lautheit", audioFields(draft.loudnessKeys, draft, true)),
    );
  if (draft.supportsPodcast && !draft.readOnly)
    content.append(
      ...section("Podcast", audioFields(draft.podcastKeys, draft, true)),
    );
  if (draft.supportsChapters)
    content.append(
      ...section(
        "Kapitel",
        node(
          "div",
          {},
          editValue(
            draft.chapters,
            (value) => {
              draft.chapters = value;
              edited();
            },
            "chapters",
            draft.readOnly,
          ),
          interchange("Chapters"),
        ),
      ),
    );
  if (draft.videoNFO)
    content.append(
      ...section(
        "Kodi-NFO",
        fieldGrid(draft.videoNFO, (key, value) => {
          draft.videoNFO[key] = value;
          edited();
        }),
      ),
    );
  if (draft.layers?.length)
    content.append(
      ...section(
        "Tag-Schichten",
        node(
          "div",
          {},
          ...draft.layers.map((layer) =>
            node(
              "div",
              { class: "row spaced" },
              node(
                "span",
                {},
                `${layer.kind} · ${layer.version} · ${layer.fields.join(", ")}`,
              ),
              layer.strippable
                ? button("Entfernen …", async () => {
                    if (
                      await modal("Tag-Schicht entfernen?", layer.kind, [
                        { title: "Abbrechen", value: false },
                        { title: "Entfernen", value: true, danger: true },
                      ])
                    )
                      await act("stripLayer", {
                        path: draft.path,
                        layer: layer.kind,
                      });
                  })
                : null,
            ),
          ),
        ),
      ),
    );
}
function renderPlaylist(content) {
  const fields = Object.fromEntries(
    Object.entries(draft.fields).filter(([key]) => key !== "entries"),
  );
  content.append(
    ...section(
      "Playlist",
      fieldGrid(
        fields,
        (key, value) => {
          draft.fields[key] = value;
          edited();
        },
        draft.supportedFields,
      ),
    ),
  );
  const table = node(
    "table",
    {},
    node(
      "thead",
      {},
      node(
        "tr",
        {},
        ...["Titel", "Interpret", "Datei"].map((title) =>
          node("th", {}, t(title)),
        ),
      ),
    ),
  );
  table.append(
    node(
      "tbody",
      {},
      ...draft.fields.entries.map((entry, index) => {
        const info = draft.playlist.entries[index];
        return node(
          "tr",
          {},
          node(
            "td",
            {},
            node("input", {
              value: entry.title,
              disabled: !draft.supportedFields.includes("entryTitle"),
              "aria-label": `${index + 1}: ${t("Titel")}`,
              oninput: (event) => {
                entry.title = event.target.value;
                edited();
              },
            }),
          ),
          node(
            "td",
            {},
            node("input", {
              value: entry.performer,
              disabled: !draft.supportedFields.includes("entryPerformer"),
              "aria-label": `${index + 1}: ${t("Interpret")}`,
              oninput: (event) => {
                entry.performer = event.target.value;
                edited();
              },
            }),
          ),
          node(
            "td",
            {},
            info?.exists && info.resolvedPath
              ? button(info.resolvedPath.split("/").pop(), () =>
                  invoke("new_window", { paths: [info.resolvedPath] }),
                )
              : node("span", { class: "subtle" }, info?.location || ""),
          ),
        );
      }),
    ),
  );
  content.append(...section("Einträge", table));
  if (draft.playlist.info?.length)
    content.append(...section("Informationen", readonly(draft.playlist.info)));
}
function interchange(kind) {
  return node(
    "div",
    { class: "row spaced" },
    button("Importieren …", async () => {
      const [source] = await choose();
      if (source) await act(`import${kind}`, { path: draft.path, source });
    }),
    button("Exportieren …", async () => {
      const [destination] = await choose(
        "save",
        kind === "LRC" ? "lyrics.lrc" : "chapters.txt",
      );
      if (destination)
        await act(`export${kind}`, { path: draft.path, destination });
    }),
  );
}
async function renderBatch() {
  const selected = state.entries.filter((entry) =>
    state.selection.includes(entry.path),
  );
  const kinds = new Set(selected.map((entry) => entry.kind));
  $("window-title").querySelector("strong").textContent =
    `${state.selection.length} ${t("Dateien")}`;
  $("window-subtitle").textContent = t("Stapelbearbeitung");
  const content = node(
    "div",
    { class: "editor-content" },
    node("h1", {}, t("Stapelbearbeitung")),
    node(
      "p",
      { class: "batch-note" },
      t("Nur ausdrücklich geänderte Felder werden auf die Auswahl übertragen."),
    ),
  );
  $("editor").replaceChildren(content);
  content.append(
    node(
      "div",
      { class: "row" },
      button("Regeln …", rules),
      button("Dateiname …", filename),
      button("Prüfen …", check),
      button("Export / Import …", toolsMenu),
    ),
  );
  if (kinds.size !== 1 || kinds.has("invoice") || kinds.has("playlist")) {
    content.append(
      node(
        "p",
        { class: "notice" },
        t(
          "Audio, Bilder, E-Books und Dokumente bitte getrennt auswählen, um sie gemeinsam zu bearbeiten.",
        ),
      ),
    );
    return;
  }
  const schema = await request("batchInfo");
  const first = schema.first;
  if (first.kind === "image" && !("rating" in first.fields))
    first.fields.rating = null;
  if (first.kind === "audio")
    content.append(
      await batchArtwork(),
      node(
        "div",
        { class: "row spaced" },
        button("Tracks nummerieren", () => act("batchNumber")),
        button("Titel aus Dateinamen", () => act("batchTitles")),
        button("Online nachschlagen …", onlineLookup),
      ),
    );
  const keys =
    first.kind === "audio"
      ? [...mainTags, ...schema.loudnessKeys]
      : Object.keys(first.fields || {}).filter(
          (key) =>
            !Array.isArray(first.fields[key]) ||
            !first.fields[key].some((item) => typeof item === "object"),
        );
  const grid = node("div", { class: "fields" });
  for (const key of keys) {
    if (
      first.kind !== "audio" &&
      !schema.supportedFields.includes(key) &&
      key !== "rating"
    )
      continue;
    const common = schema.common[key];
    const display = Array.isArray(common) ? common.join("; ") : (common ?? "");
    const input = node("input", {
      value: display,
      disabled:
        schema.readOnly ||
        (first.kind === "audio" &&
          schema.writableKeys &&
          !schema.writableKeys.includes(key)),
      placeholder: t("Unverändert"),
      "aria-label": label(key),
      oninput: (event) => {
        batchChanges[key] =
          first.kind === "audio"
            ? [event.target.value]
            : Array.isArray(first.fields[key])
              ? event.target.value
                  .split(";")
                  .map((value) => value.trim())
                  .filter(Boolean)
              : typeof first.fields[key] === "number" ||
                  (first.kind === "image" && key === "rating")
                ? event.target.value === ""
                  ? null
                  : Number(event.target.value)
                : event.target.value;
        $("save").disabled = false;
        $("save-all").disabled = false;
      },
    });
    if (key === "rating" && first.kind === "image") {
      const rating = node(
        "select",
        {
          "aria-label": label(key),
          onchange: (event) => {
            if (event.target.value === "__unchanged")
              delete batchChanges.rating;
            else
              batchChanges.rating =
                event.target.value === "" ? null : Number(event.target.value);
            $("save").disabled = false;
            $("save-all").disabled = false;
          },
        },
        node(
          "option",
          { value: "__unchanged", selected: schema.mixed.includes(key) },
          t("Unverändert"),
        ),
        ...first.ratingOptions.map((option) =>
          node(
            "option",
            {
              value: option.value ?? "",
              selected: !schema.mixed.includes(key) && option.value === common,
            },
            option.label,
          ),
        ),
      );
      grid.append(node("label", {}, label(key)), rating);
    } else
      grid.append(
        node("label", {}, label(key)),
        first.kind === "audio" ||
          (first.kind === "image" &&
            [
              "title",
              "description",
              "keywords",
              "creator",
              "copyright",
            ].includes(key))
          ? node(
              "div",
              { class: "field-value" },
              input,
              button(
                "▾",
                () =>
                  copyField(
                    key,
                    first.kind === "audio" ? schema.sourceKeys : null,
                  ),
                { title: t("Aus anderem Feld kopieren") },
              ),
            )
          : input,
      );
  }
  content.append(
    ...section("Gemeinsame Felder", grid),
    button("Änderungen übernehmen", () =>
      enqueue(async () => {
        await flush();
        await renderSelection();
      }),
    ),
  );
}
async function batchArtwork() {
  const preview = node(
    "div",
    { class: "cover", id: "cover-well" },
    t("Cover hierher ziehen"),
  );
  const data = await request("batchCoverPreview");
  if (data)
    preview.replaceChildren(
      node("img", {
        src: `data:${data.mimeType};base64,${data.data}`,
        alt: t("Cover"),
      }),
    );
  const controls = node(
    "div",
    { class: "row spaced" },
    button("Cover auswählen", async () => {
      const [source] = await choose("cover");
      if (source) await act("batchCover", { action: "set", source });
    }),
    button("Cover entfernen", () => act("batchCover", { action: "remove" })),
    button("Ordner-Cover übernehmen", () =>
      act("batchCover", { action: "folder" }),
    ),
  );
  for (const size of [500, 1000, 1500])
    controls.append(
      button(`${size} px`, () =>
        act("batchCover", { action: "convert", maxPixelSize: size }),
      ),
    );
  controls.append(
    button("Nach JPEG wandeln", () =>
      act("batchCover", { action: "convert", format: "jpeg" }),
    ),
    button("Metadaten entfernen", () =>
      act("batchCover", { action: "convert", stripMetadata: true }),
    ),
  );
  return node("div", { class: "hero" }, preview, controls);
}
function renderEmpty() {
  $("window-title").querySelector("strong").textContent = "Tag Explosion";
  $("window-subtitle").textContent = "";
  $("editor").replaceChildren(
    node(
      "div",
      { class: "empty" },
      node("img", { src: "icon.png", alt: "" }),
      node("h1", {}, "Tag Explosion"),
      node(
        "p",
        {},
        t(
          "Dateien oder Ordner hierher ziehen, um Metadaten anzuzeigen und zu bearbeiten.",
        ),
      ),
      node(
        "div",
        { class: "row" },
        button("Dateien öffnen …", async () => openFiles(await choose())),
        button("Ordner öffnen …", async () =>
          openFiles(await choose("folder")),
        ),
      ),
      node(
        "div",
        { class: "formats" },
        ...[
          ["Audio / Video", "MP3 · FLAC · M4A · OGG · OPUS · MP4 · MKV"],
          ["Bilder", "JPEG · PNG · TIFF · HEIC · RAW"],
          ["E-Books", "EPUB · PDF · MOBI · AZW3"],
          ["Dokumente", "DOCX · ODT · CBZ · XML"],
        ].map(([title, text]) =>
          node("div", {}, node("strong", {}, t(title)), text),
        ),
      ),
    ),
  );
}
function validationIssues(issues) {
  const severity = { error: "Fehler", warning: "Warnung", information: "Information" };
  return node("div", { class: "validation-issues" }, ...issues.map(issue =>
    node("article", { class: "validation-issue" },
      node("div", { class: "issue-heading" },
        node("strong", {}, t(severity[issue.severity] || issue.severity)),
        issue.code ? node("code", {}, issue.code) : null),
      node("p", {}, issue.message),
      issue.location ? node("details", {}, node("summary", {}, label("location")), node("pre", {}, issue.location)) : null)));
}
function readonly(value) {
  if (Array.isArray(value)) {
    if (!value.length)
      return node("p", { class: "notice" }, t("Keine Einträge"));
    const table = node("table"),
      keys = [
        ...new Set(
          value.flatMap((item) =>
            item && typeof item === "object" ? Object.keys(item) : [],
          ),
        ),
      ];
    if (!keys.length)
      return node(
        "div",
        {},
        ...value.map((item) => node("p", {}, String(item))),
      );
    table.append(
      node(
        "thead",
        {},
        node("tr", {}, ...keys.map((key) => node("th", {}, label(key)))),
      ),
    );
    table.append(
      node(
        "tbody",
        {},
        ...value.map((item) =>
          node(
            "tr",
            {},
            ...keys.map((key) =>
              node(
                "td",
                {},
                item[key] && typeof item[key] === "object"
                  ? readonly(item[key])
                  : String(item[key] ?? ""),
              ),
            ),
          ),
        ),
      ),
    );
    return node("div", { class: "table-wrap" }, table);
  }
  if (value && typeof value === "object")
    return node(
      "div",
      {},
      ...Object.entries(value).map(([key, item]) =>
        node(
          "div",
          { class: "invoice-field" },
          node("span", {}, label(key)),
          item && typeof item === "object"
            ? readonly(item)
            : node("span", { class: "field-text" }, String(item ?? "")),
        ),
      ),
    );
  return node("span", {}, String(value ?? ""));
}
async function technical(content) {
  content.append(
    node("h2", {}, t("Technische Informationen")),
    node("p", { class: "notice" }, t("Lade …")),
  );
  technicalLoading = true;
  operations++;
  $("cancel").hidden = false;
  let report;
  try {
    report = await request("info", { path: draft.path });
  } finally {
    technicalLoading = false;
    operations--;
    $("cancel").hidden = !state.busy && !state.loading && !operations;
  }
  if (report.cancelled) {
    content.replaceChildren(node("p", { class: "notice" }, t("Abgebrochen")));
    return;
  }
  content.replaceChildren(node("h2", {}, t("Technische Informationen")));
  const search = node("input", {
    type: "search",
    placeholder: t("Technische Felder suchen"),
    class: "wide",
  });
  const tracks = node("div");
  function draw() {
    const query = search.value.toLocaleLowerCase();
    tracks.replaceChildren(
      ...report.tracks.flatMap((track) => {
        const fields = track.fields.filter((field) =>
          `${field.key} ${field.value}`.toLocaleLowerCase().includes(query),
        );
        return fields.length ? section(track.type, readonly(fields)) : [];
      }),
    );
  }
  search.addEventListener("input", draw);
  draw();
  content.append(
    search,
    tracks,
    node(
      "details",
      {},
      node("summary", {}, t("Textausgabe")),
      node("pre", {}, report.text),
    ),
  );
}
async function metadata(content) {
  content.append(node("h2", {}, t("Alle Metadaten")));
  for (const group of await request("imageMetadata", { path: draft.path }))
    content.append(...section(group.name, readonly(group.fields)));
}
async function invoice(content) {
  let document = draft.invoice;
  if (!document) document = await request("invoice", { path: draft.path });
  if (!document) {
    content.append(
      node(
        "p",
        { class: "notice" },
        t("Keine eingebettete E-Rechnung gefunden."),
      ),
    );
    return;
  }
  content.append(
    node("h1", {}, document.profile?.standard || t("E-Rechnung")),
    node(
      "p",
      { class: "notice" },
      `${document.syntax} · ${document.profile?.profile || ""}`,
    ),
  );
  content.append(...section("Zusammenfassung", readonly(document.summary)));

  content.append(
    button("Lokal prüfen …", async () => {
      const checked = await act("validate", { path: draft.path }, false);
      draft.invoice = checked.invoice;
      const stale = node(
        "p",
        { class: "error-message", hidden: checked.current },
        t("Die Quelldatei hat sich seit der Prüfung geändert."),
      );
      const report = node(
        "div",
        {},
        stale,
        node("h3", {}, checked.title),
        readonly(checked.steps),
        validationIssues(checked.result.issues),
        checked.result.pdf ? readonly(checked.result.pdf) : null,
        node("p", { class: "notice" }, checked.result.notice),
        button("Bericht sichern …", async () => {
          const [destination] = await choose(
            "save",
            "e-invoice-validation.txt",
          );
          if (destination)
            await act("exportValidation", { destination }, false);
        }),
      );
      const timer = setInterval(
        () =>
          request("validationCurrent")
            .then((current) => {
              stale.hidden = current;
              if (!current)
                report.querySelector("h3").textContent = t(
                  "Datei verändert · erneut prüfen",
                );
            })
            .catch(() => {
              stale.hidden = false;
            }),
        1500,
      );
      try {
        await modal("Prüfergebnis", report);
      } finally {
        clearInterval(timer);
      }
      content.replaceChildren();
      await invoice(content);
    }),
  );
  if (document.warnings?.length)
    content.append(
      node(
        "details",
        {},
        node(
          "summary",
          {},
          `${t("Grundprüfung (ohne XSD/Schematron)")} · ${document.warnings.length}`,
        ),
        readonly(document.warnings),
      ),
    );
  const search = node("input", {
    type: "search",
    placeholder: t("Feld, Bezeichnung oder Wert suchen"),
    class: "wide spaced",
  });
  const fields = node("div"),
    termsOnly = node("input", { type: "checkbox" });
  termsOnly.addEventListener("change", draw);
  function draw() {
    const query = search.value.toLocaleLowerCase();
    fields.replaceChildren(
      ...document.fields
        .filter(
          (field) =>
            !termsOnly.checked || field.term || field.attributeTerms?.length,
        )
        .filter((field) =>
          `${field.term || ""} ${field.termName || ""} ${field.value || ""} ${field.path || ""}`
            .toLocaleLowerCase()
            .includes(query),
        )
        .map((field) =>
          node(
            "div",
            { class: "invoice-field" },
            node(
              "div",
              {},
              field.termName || field.name || field.path,
              node(
                "small",
                {},
                [field.term, field.path].filter(Boolean).join(" · "),
              ),
            ),
            node(
              "div",
              { class: `field-text level-${Math.min(field.level, 6)}` },
              field.value || "",
              field.valueNote ? node("small", {}, field.valueNote) : null,
              ...(field.attributes || []).map((attribute) => {
                const term = field.attributeTerms?.find(
                  (item) => item.attribute === attribute.name,
                );
                return node(
                  "p",
                  { class: "attribute" },
                  [
                    term?.term,
                    term?.termName || attribute.name,
                    attribute.value,
                  ]
                    .filter(Boolean)
                    .join(" · "),
                );
              }),
            ),
          ),
        ),
    );
  }
  search.addEventListener("input", draw);
  draw();
  content.append(
    search,
    node("label", {}, termsOnly, t("Nur EN-16931-Felder")),
    ...section("Alle Felder", fields),
  );
}
async function chooseCover() {
  if (!draft || draft.kind === "document") return;
  const paths = await choose("cover");
  if (paths.length)
    await act(state.selection.length > 1 ? "batchCover" : "setCover", {
      action: "set",
      path: draft?.path,
      source: paths[0],
      index: coverIndex,
    });
}
async function coverTools() {
  const path = draft.path,
    actions = node("div", { class: "row" });
  for (const [title, method, params] of [
    ["Ordner-Cover übernehmen", "folderCover", {}],
    ["Cover entfernen", "removeCover", {}],
    ["Nach JPEG wandeln", "convertCover", { format: "jpeg" }],
    ["500 px", "convertCover", { maxPixelSize: 500 }],
    ["1000 px", "convertCover", { maxPixelSize: 1000 }],
    ["1500 px", "convertCover", { maxPixelSize: 1500 }],
    ["Metadaten entfernen", "convertCover", { stripMetadata: true }],
  ])
    actions.append(
      button(title, async () => {
        dismissDialog();
        await act(method, { path, index: coverIndex, ...params });
      }),
    );
  actions.append(
    button("Cover exportieren …", async () => {
      const [destination] = await choose("save", "cover.jpg");
      if (destination) {
        dismissDialog();
        await act("exportCover", { path, index: coverIndex, destination });
      }
    }),
  );
  await modal(
    "Cover-Werkzeuge",
    node(
      "div",
      {},
      draft.artworks?.[coverIndex]?.analysis
        ? readonly(draft.artworks[coverIndex].analysis)
        : null,
      actions,
    ),
  );
}
async function history() {
  await enqueue(flush);
  const path = draft.path,
    versions = await request("history", { path });
  const list = node("div");
  if (!versions.length)
    list.append(node("p", {}, t("Keine Sicherung im Papierkorb vorhanden.")));
  for (const version of versions)
    list.append(
      node(
        "div",
        { class: "finding" },
        node("strong", {}, new Date(version.entry.date).toLocaleString()),
        node(
          "small",
          {},
          `${version.entry.reason} · ${version.entry.size} B · ${version.entry.originalPath}`,
        ),
        node(
          "div",
          { class: "row spaced" },
          button("Vergleichen …", async () => {
            const diff = await request("historyDiff", {
              path,
              id: version.id || version.entry.id,
            });
            await modal("Änderungen", readonly(diff));
          }),
          button("Wiederherstellen …", async () => {
            if (
              await modal(
                "Version wiederherstellen?",
                t(
                  "Der jetzige Stand wird vorher gesichert. Ungespeicherte Änderungen werden verworfen.",
                ),
                [
                  { title: "Abbrechen", value: false },
                  { title: "Wiederherstellen", value: true, danger: true },
                ],
              )
            )
              await act("restore", {
                path,
                id: version.id || version.entry.id,
                confirmed: true,
              });
          }),
        ),
      ),
    );
  await modal("Versionen", list);
}
async function filename() {
  const input = node("input", {
    value: localStorage.getItem("filenamePattern") || "%{artist} - %{title}",
    class: "wide",
    "aria-label": t("Dateinamenmuster"),
  });
  const preview = node("div", { class: "spaced" });
  const controls = node(
    "div",
    { class: "row spaced" },
    button("Umbenennen: Vorschau", async () => {
      await enqueue(flush);
      preview.replaceChildren(
        readonly(await request("renamePreview", { pattern: input.value })),
      );
    }),
  );
  const choice = await modal(
    "Dateiname ↔ Tags",
    node(
      "div",
      {},
      input,
      node(
        "p",
        { class: "notice" },
        t(
          "Felder: %{ARTIST}, %{ALBUM}, %{TITLE}, %{TRACKNUMBER}. Umbenennen verändert Dateinamen; Tags aus Dateinamen bleiben bis zum Speichern im Puffer.",
        ),
      ),
      controls,
      preview,
    ),
    [
      { title: "Abbrechen", value: "cancel" },
      { title: "Tags aus Dateinamen", value: "parse" },
      { title: "Umbenennen", value: "rename", primary: true },
    ],
  );
  if (choice === "parse" || choice === "rename") {
    localStorage.setItem("filenamePattern", input.value);
    await act(choice === "parse" ? "parseFilename" : "rename", {
      pattern: input.value,
    });
  }
}
async function rules() {
  return editRules({
    node,
    button,
    t,
    modal,
    request,
    enqueue,
    flush,
    act,
    choose,
    readonly,
  });
}
async function toolsMenu() {
  const content = node("div", { class: "row" });
  const action = (title, callback) =>
    content.append(
      button(title, async () => {
        dismissDialog();
        await callback();
      }),
    );
  action("Tags exportieren …", async () => {
    const [destination] = await choose("save", "tags.json");
    if (destination) await act("export", { destination });
  });
  action("Tags importieren …", async () => {
    const [source] = await choose("archive");
    if (source) await act("import", { source });
  });
  action("Playlist exportieren …", async () => {
    const [destination] = await choose("save", "playlist.m3u8");
    if (destination)
      await act("exportPlaylist", {
        destination,
        format: destination.split(".").pop().toLowerCase(),
        absolutePaths: false,
      });
  });
  action("Regeln …", rules);
  action("Änderungen verwerfen", async () => {
    if (
      await modal(
        "Änderungen verwerfen?",
        t("Ungespeicherte Änderungen der Auswahl werden verworfen."),
        [
          { title: "Abbrechen", value: false },
          { title: "Verwerfen", value: true, danger: true },
        ],
      )
    )
      await act("revert");
  });
  action("Speicherergebnisse", () =>
    modal(
      "Speicherergebnisse",
      node(
        "div",
        {},
        readonly(state.batch || []),
        button("Fehlgeschlagene wiederholen", () => {
          dismissDialog();
          act("retry");
        }),
      ),
    ),
  );
  await modal("Werkzeuge", content);
}
async function shiftSubtitle() {
  const input = node("input", {
    type: "number",
    value: 0,
    step: 0.1,
    "aria-label": t("Sekunden"),
  });
  if (
    await modal(
      "Untertitel verschieben",
      node(
        "div",
        {},
        node("p", {}, t("Zeitverschiebung in Sekunden (negativ oder positiv)")),
        input,
      ),
      [
        { title: "Abbrechen", value: false },
        { title: "Verschieben", value: true, primary: true },
      ],
    )
  )
    await act("shiftSubtitle", {
      path: draft.path,
      milliseconds: Math.round(Number(input.value) * 1000),
    });
}
async function check() {
  const result = await act(
    "check",
    {
      paths: state.selection.length
        ? state.selection
        : state.entries.map((entry) => entry.path),
    },
    false,
  );
  await modal("Konsistenzprüfung", readonly(result));
}
async function onlineLookup() {
  if (!preferences.onlineServicesAllowed || !preferences.privacyAcknowledged) {
    await modal(
      "Online-Dienste",
      t(
        "Bitte Online-Dienste und den Datenschutzhinweis in den Einstellungen freigeben.",
      ),
    );
    return;
  }
  await enqueue(flush);
  const fields = await request("lookupQuery");
  const source = node(
    "select",
    { "aria-label": t("Dienst") },
    ...["musicbrainz", "discogs", "acoustid"].map((name) =>
      node("option", { value: name }, name),
    ),
  );
  const results = node("div");
  const search = button("Suchen", async () => {
    search.disabled = true;
    try {
      const found = await request("lookupSearch", {
        source: source.value,
        query: fields,
        path: draft?.path,
      });
      results.replaceChildren(
        ...found.map((candidate) =>
          node(
            "div",
            { class: "finding" },
            node("strong", {}, `${candidate.artist} — ${candidate.album}`),
            node(
              "small",
              {},
              `${candidate.year} · ${candidate.label} · ${candidate.trackCount || ""}`,
            ),
            button("Details …", async () => {
              const details = await request("lookupDetails", {
                id:
                  candidate.id ||
                  `${candidate.source}:${candidate.identifiers.musicBrainzReleaseID || candidate.identifiers.discogsReleaseID}`,
              });
              await lookupDetails(details);
            }),
          ),
        ),
      );
    } catch (error) {
      results.replaceChildren(
        node("p", { class: "error-message" }, String(error)),
      );
    } finally {
      search.disabled = false;
    }
  });
  await modal(
    "Online nachschlagen …",
    node(
      "div",
      {},
      fieldGrid(fields, (key, value) => {
        fields[key] = value;
      }),
      node("div", { class: "row spaced" }, source, search),
      results,
    ),
  );
}
async function lookupDetails(details) {
  const overwrite = node("input", { type: "checkbox" }),
    cover = node("input", { type: "checkbox" }),
    identifiers = node("input", { type: "checkbox", checked: true });
  const mapping = {},
    preview = node("div", { class: "rule-preview" });
  const options = () => ({
    id: details.id,
    overwriteExisting: overwrite.checked,
    includeCover: cover.checked,
    includeIdentifiers: identifiers.checked,
    mapping,
  });
  const load = async () => {
    const plans = await request("lookupPreview", options());
    preview.replaceChildren(
      ...plans.map((plan) => {
        const select = node(
          "select",
          {
            "aria-label": plan.path,
            onchange: (event) => {
              mapping[plan.path] = Number(event.target.value);
              load().catch(showError);
            },
          },
          node(
            "option",
            { value: -1, selected: plan.trackIndex === -1 },
            t("Keine Zuordnung"),
          ),
          ...details.tracks.map((track, index) =>
            node(
              "option",
              { value: index, selected: index === plan.trackIndex },
              `${track.discNumber}.${track.number} ${track.title}`,
            ),
          ),
        );
        return node(
          "div",
          { class: "finding" },
          node("strong", {}, plan.path.split("/").pop()),
          select,
          readonly(plan.changes),
          !plan.applicable
            ? node(
                "p",
                { class: "notice" },
                t("Ohne Zuordnung bleibt diese Datei unverändert."),
              )
            : null,
        );
      }),
    );
  };
  for (const input of [overwrite, cover, identifiers])
    input.addEventListener("change", () => load().catch(showError));
  await load();
  const content = node(
    "div",
    {},
    node(
      "div",
      { class: "row" },
      node("label", {}, overwrite, t("Vorhandene Werte ersetzen")),
      node("label", {}, identifiers, t("Kennungen übernehmen")),
      node("label", {}, cover, t("Cover übernehmen")),
    ),
    preview,
  );
  if (
    await modal("Gefundene Metadaten", content, [
      { title: "Abbrechen", value: false },
      { title: "In Bearbeitungspuffer übernehmen", value: true, primary: true },
    ])
  )
    await act("lookupApply", options());
}
async function settings() {
  preferences = await request("preferences");
  const content = node("div");
  const tools = await request("tools");
  content.append(
    node("h3", {}, t("Externe Werkzeuge")),
    readonly(
      Object.entries(tools).map(([name, available]) => ({
        name,
        status: available ? t("Installiert") : t("Nicht installiert"),
      })),
    ),
  );
  if (Object.values(tools).some((value) => !value))
    content.append(
      node(
        "details",
        {},
        node("summary", {}, t("Fehlende Werkzeuge installieren")),
        node(
          "p",
          { class: "notice" },
          t(
            "MediaInfo zeigt Technikdaten, ExifTool bearbeitet Bild/PDF-Metadaten, ImageMagick wandelt Cover, Chromaprint erstellt Fingerabdrücke und Calibre ergänzt E-Book-Formate.",
          ),
        ),
        node("h3", {}, "Linux Mint / Ubuntu"),
        node(
          "pre",
          {},
          "sudo apt install mediainfo libimage-exiftool-perl imagemagick libchromaprint-tools calibre",
        ),
        node("h3", {}, "Arch / CachyOS"),
        node(
          "pre",
          {},
          "sudo pacman -S mediainfo perl-image-exiftool imagemagick chromaprint calibre",
        ),
      ),
    );
  const options = [
    ["trashBackupBeforeSave", "Vor jeder Änderung im Papierkorb sichern"],
    ["autoBackupBeforeBatchSave", "Tag-Backup vor Stapelspeichern"],
    ["writeImageSidecar", "Bild-Metadaten in XMP-Sidecar schreiben"],
    ["writeID3v23", "ID3v2.3 statt ID3v2.4 schreiben"],
    ["onlineServicesAllowed", "Online-Dienste erlauben"],
    ["privacyAcknowledged", "Datenschutzhinweis gelesen und zugestimmt"],
  ];
  for (const [key, title] of options)
    content.append(
      node(
        "p",
        {},
        node(
          "label",
          {},
          node("input", {
            type: "checkbox",
            checked: preferences[key],
            onchange: (event) => {
              preferences[key] = event.target.checked;
            },
          }),
          ` ${t(title)}`,
        ),
      ),
    );
  content.append(
    node(
      "p",
      { class: "notice" },
      t(
        "Online-Suchen senden die gewählten Suchbegriffe an MusicBrainz oder Discogs. AcoustID sendet einen lokal berechneten Fingerabdruck und die Spieldauer. Anfragen erfolgen nur nach Ihrer Aktion.",
      ),
    ),
  );
  const theme = node(
    "select",
    { "aria-label": t("Darstellung") },
    ...[
      ["auto", "Automatisch"],
      ["light", "Hell"],
      ["dark", "Dunkel"],
    ].map(([value, title]) =>
      node(
        "option",
        {
          value,
          selected: (localStorage.getItem("theme") || "auto") === value,
        },
        t(title),
      ),
    ),
  );
  theme.addEventListener("change", () => {
    localStorage.setItem("theme", theme.value);
    applyTheme();
  });
  content.append(
    node("div", { class: "row" }, node("label", {}, t("Darstellung")), theme),
  );
  for (const [account, title] of [
    ["discogs-token", "Discogs-Token"],
    ["acoustid-client-key", "AcoustID-Schlüssel"],
  ]) {
    const value = node("input", {
      type: "password",
      autocomplete: "off",
      "aria-label": title,
      placeholder: title,
    });
    content.append(
      node(
        "div",
        { class: "row spaced" },
        value,
        button("Im Schlüsselbund speichern", async () => {
          await invoke("save_credential", { account, value: value.value });
          value.value = "";
          status(t("Zugangsdaten gespeichert"));
        }),
      ),
    );
  }
  const automatic = node("input", {
    type: "checkbox",
    checked: localStorage.getItem("automaticUpdates") === "true",
  });
  content.append(
    node(
      "p",
      {},
      node(
        "label",
        {},
        automatic,
        ` ${t("Automatisch nach Updates suchen (einmal täglich)")}`,
      ),
    ),
  );
  content.append(
    node(
      "div",
      { class: "row spaced" },
      button("Nach Updates suchen …", () => updates(false)),
    ),
  );
  if (
    await modal("Einstellungen", content, [
      { title: "Schließen", value: false },
      { title: "Speichern", value: true, primary: true },
    ])
  ) {
    preferences = await request("preferences", { values: preferences });
    localStorage.setItem("automaticUpdates", String(automatic.checked));
  }
}
function applyTheme() {
  const theme = localStorage.getItem("theme") || "auto";
  if (theme === "auto") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
}
async function updates(automatic = false) {
  const found = await invoke("check_update");
  if (!found.available) {
    if (!automatic) await modal("Updates", t("Diese Version ist aktuell."));
    return;
  }
  if (
    await modal(
      "Update verfügbar",
      `${found.version}\n\n${found.notes || ""}`,
      [
        { title: "Später", value: false },
        { title: "Herunterladen und installieren", value: true, primary: true },
      ],
    )
  ) {
    await enqueue(flush);
    await invoke("install_update", { version: found.version });
    await modal(
      "Update installiert",
      t(
        "Die neue Version wird beim nächsten regulären Start verwendet. Ungespeicherte Änderungen bleiben in dieser Sitzung erhalten.",
      ),
    );
  }
}
async function close() {
  if (closingDecision) return;
  closingDecision = true;
  try {
    if (technicalLoading) await request("cancel", { operation: "info" });
    await enqueue(async () => {
      await flush();
      const result = await invoke("close_window");
      if (!result.closed) {
        updateState(result.state);
        await decisions();
        if (!state.dirty && !state.conflict) {
          const next = await invoke("close_window");
          if (!next.closed) updateState(next.state);
        }
      }
    });
  } finally {
    closingDecision = false;
  }
}
$("open").onclick = () => choose().then(openFiles).catch(showError);
$("open-folder").onclick = () =>
  choose("folder").then(openFiles).catch(showError);
$("save").onclick = () => act("save");
$("save-all").onclick = () => act("saveAll");
$("check").onclick = () => check().catch(showError);
$("settings").onclick = () => settings().catch(showError);
$("new-window").onclick = () => invoke("new_window").catch(showError);
$("sidebar-toggle").onclick = () =>
  document.body.classList.toggle("sidebar-hidden");
$("remove").onclick = () => act("remove");
$("cancel").onclick = () =>
  request("cancel").then(updateState).catch(showError);
for (const id of ["search", "kind", "sort", "dirty-only", "errors-only"])
  $(id).addEventListener(id === "search" ? "input" : "change", () =>
    act(
      "filter",
      {
        search: $("search").value,
        kind: $("kind").value,
        sort: $("sort").value,
        dirtyOnly: $("dirty-only").checked,
        errorsOnly: $("errors-only").checked,
      },
      false,
    ),
  );
$("file-list").addEventListener("keydown", (event) => {
  if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  let index = state.entries.findIndex((entry) => entry.path === lastSelected);
  index =
    event.key === "Home"
      ? 0
      : event.key === "End"
        ? state.entries.length - 1
        : Math.max(
            0,
            Math.min(
              state.entries.length - 1,
              index + (event.key === "ArrowDown" ? 1 : -1),
            ),
          );
  if (state.entries[index]) selectEntry(state.entries[index].path, event);
});
document.addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey)) return;
  const key = event.key.toLowerCase();
  if (key === "s") {
    event.preventDefault();
    act(event.shiftKey ? "saveAll" : "save");
  }
  if (key === "o") {
    event.preventDefault();
    choose().then(openFiles);
  }
  if (key === "w") {
    event.preventDefault();
    close();
  }
  if (key === "n") {
    event.preventDefault();
    invoke("new_window").catch(showError);
  }
  if (key === ",") {
    event.preventDefault();
    settings();
  }
  if (key === "a" && event.target === $("file-list")) {
    event.preventDefault();
    act("select", { paths: state.entries.map((entry) => entry.path) });
  }
});
await tauri.event.listen("menu-action", (event) => {
  const actions = {
    new: () => invoke("new_window"),
    open: () => choose().then(openFiles),
    folder: () => choose("folder").then(openFiles),
    save: () => act("save"),
    saveAll: () => act("saveAll"),
    close,
    settings,
    history: () => (draft ? history() : undefined),
    revert: () => toolsMenu(),
    updates: () => updates(false),
    about: async () =>
      modal(
        "Tag Explosion",
        `Tag Explosion ${await tauri.app.getVersion()}\n© 2026 Daniel Müller · MIT\nSwift · Rust · Tauri\nhttps://github.com/DanielMuellerIR/tag_explosion`,
      ),
  };
  Promise.resolve()
    .then(actions[event.payload] || (() => {}))
    .catch(showError);
});
let lastUpdateProgress = 0;
await tauri.event.listen("update-progress", (event) => {
  if (
    Date.now() - lastUpdateProgress < 100 &&
    event.payload.downloaded !== event.payload.total
  )
    return;
  lastUpdateProgress = Date.now();
  const megabytes = (value) => (value / 1048576).toFixed(1);
  status(
    `${t("Update wird geladen")} · ${megabytes(event.payload.downloaded)} MiB${event.payload.total ? " / " + megabytes(event.payload.total) + " MiB" : ""}`,
  );
});
await tauri.event.listen("request-close", close);
await tauri.event.listen("open-files", (event) => openFiles(event.payload));
await nativeWindow.onDragDropEvent(async (event) => {
  const payload = event.payload;
  document.body.classList.toggle(
    "drop-active",
    payload.type === "enter" || payload.type === "over",
  );
  if (payload.type !== "drop") return;
  document.body.classList.remove("drop-active");
  const cover = $("cover-well"),
    scale = await nativeWindow.scaleFactor();
  const box = cover?.getBoundingClientRect(),
    x = payload.position.x / scale,
    y = payload.position.y / scale;
  if (
    box &&
    payload.paths.length === 1 &&
    x >= box.left &&
    x <= box.right &&
    y >= box.top &&
    y <= box.bottom
  )
    await act(state.selection.length > 1 ? "batchCover" : "setCover", {
      action: "set",
      path: draft?.path,
      source: payload.paths[0],
      index: coverIndex,
    });
  else await openFiles(payload.paths);
});
for (const element of document.querySelectorAll("button,option,label")) {
  for (const child of element.childNodes)
    if (child.nodeType === Node.TEXT_NODE && child.textContent.trim())
      child.textContent = t(child.textContent.trim());
}
for (const input of document.querySelectorAll("[placeholder]"))
  input.placeholder = t(input.placeholder);
document.documentElement.lang = language.toLowerCase().startsWith("de")
  ? "de"
  : "en";
applyTheme();
try {
  await request("hello");
  await refresh();
  await renderSelection();
  preferences = await request("preferences");
  const paths = await invoke("startup_files");
  if (paths.length) await openFiles(paths);
  const checkUpdates = () => {
    const previous = Number(localStorage.getItem("lastUpdateCheck") || 0);
    if (
      nativeWindow.label === "main" &&
      localStorage.getItem("automaticUpdates") === "true" &&
      Date.now() - previous >= 86400000
    ) {
      localStorage.setItem("lastUpdateCheck", String(Date.now()));
      updates(true).catch(() =>
        status(t("Automatische Updateprüfung derzeit nicht erreichbar")),
      );
    }
  };
  setTimeout(checkUpdates, 3000);
  setInterval(checkUpdates, 3600000);
} catch (error) {
  showError(error);
}
