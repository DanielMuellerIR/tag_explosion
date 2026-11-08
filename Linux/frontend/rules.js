// Der Editor erzeugt das gemeinsame TagRuleDocument; Auswertung und
// Schreibentscheidungen liegen ausschließlich in der Swift-Anwendungsschicht.
export async function editRules(api) {
  const { node, button, t, modal, request, enqueue, flush, act, choose } = api;
  await enqueue(flush);
  const schema = await request("rulesSchema");
  let document = structuredClone(schema.templates[0].document),
    selected = 0;
  const list = node("div", {
    class: "rule-list",
    role: "listbox",
    "aria-label": t("Regeln"),
  });
  const form = node("div", { class: "rule-form" });
  const error = node("p", { class: "error-message" });
  const preview = node("div", { class: "rule-preview" });
  const advanced = node("textarea", {
    class: "wide",
    rows: 12,
    "aria-label": t("Regeldatei"),
  });
  function safe(action) {
    return async () => {
      error.textContent = "";
      try {
        await action();
      } catch (failure) {
        error.textContent = String(failure);
      }
    };
  }
  function select(values, current, changed, title) {
    const control = node(
      "select",
      {
        "aria-label": t(title),
        onchange: (event) => changed(event.target.value),
      },
      ...values.map((value) =>
        node(
          "option",
          { value: value.id, selected: value.id === current },
          value.title,
        ),
      ),
    );
    return control;
  }
  function checkbox(title, checked, changed) {
    return node(
      "label",
      { class: "row" },
      node("input", {
        type: "checkbox",
        checked,
        onchange: (event) => changed(event.target.checked),
      }),
      ` ${t(title)}`,
    );
  }
  function input(value, changed, title, type = "text") {
    return node("input", {
      type,
      value: value ?? "",
      "aria-label": t(title),
      oninput: (event) => {
        changed(
          type === "number" ? Number(event.target.value) : event.target.value,
        );
        syncJSON();
      },
    });
  }
  function syncJSON() {
    advanced.value = JSON.stringify(document, null, 2);
  }
  function redraw() {
    selected = Math.max(0, Math.min(selected, document.rules.length - 1));
    list.replaceChildren(
      ...document.rules.map((rule, index) =>
        button(
          `${index + 1}. ${schema.actions.find((action) => action.id === rule.action)?.title || rule.action} · ${rule.field || "TRACKNUMBER"}`,
          () => {
            selected = index;
            redraw();
          },
          { role: "option", "aria-selected": selected === index },
        ),
      ),
    );
    form.replaceChildren();
    if (!document.rules.length) {
      form.append(
        node(
          "p",
          { class: "notice" },
          t("Eine Regel hinzufügen oder eine Vorlage auswählen."),
        ),
      );
      syncJSON();
      return;
    }
    const rule = document.rules[selected];
    const fields = node("div", { class: "fields" });
    const row = (title, control) =>
      fields.append(node("label", {}, t(title)), control);
    row(
      "Aktion",
      select(
        schema.actions,
        rule.action,
        (value) => {
          const common = {
            kinds: rule.kinds,
            when: rule.when,
            _comment: rule._comment,
          };
          const defaults = {
            set: { field: "TITLE", value: "" },
            copy: { field: "ALBUMARTIST", from: "ARTIST" },
            replace: { field: "TITLE", search: "_", replacement: " " },
            case: { field: "TITLE", mode: "title" },
            trim: { field: "*" },
            remove: { field: "COMMENT" },
            number: {
              field: "TRACKNUMBER",
              start: 1,
              sortBy: "filename",
              total: true,
            },
          };
          document.rules[selected] = {
            action: value,
            ...defaults[value],
            ...Object.fromEntries(
              Object.entries(common).filter(([, item]) => item !== undefined),
            ),
          };
          redraw();
        },
        "Aktion",
      ),
    );
    row(
      "Zielfeld",
      input(
        rule.field,
        (value) => {
          rule.field = value;
        },
        "Zielfeld",
      ),
    );
    row(
      "Medienart",
      select(
        schema.kinds,
        rule.kinds?.length === 1 ? rule.kinds[0] : "",
        (value) => {
          if (value) rule.kinds = [value];
          else delete rule.kinds;
          syncJSON();
        },
        "Medienart",
      ),
    );
    switch (rule.action) {
      case "set":
        row(
          "Wert",
          input(
            rule.value,
            (value) => {
              rule.value = value;
            },
            "Wert",
          ),
        );
        break;
      case "copy":
        row(
          "Quellfeld",
          input(
            rule.from,
            (value) => {
              rule.from = value;
            },
            "Quellfeld",
          ),
        );
        row(
          "",
          checkbox(
            "Nur leere Zielfelder füllen",
            !!rule.onlyIfEmpty,
            (value) => {
              rule.onlyIfEmpty = value;
              syncJSON();
            },
          ),
        );
        break;
      case "replace":
        row(
          "Suchen",
          input(
            rule.search,
            (value) => {
              rule.search = value;
            },
            "Suchen",
          ),
        );
        row(
          "Ersetzen durch",
          input(
            rule.replacement,
            (value) => {
              rule.replacement = value;
            },
            "Ersetzen durch",
          ),
        );
        row(
          "",
          checkbox("Regulärer Ausdruck", !!rule.regex, (value) => {
            rule.regex = value;
            syncJSON();
          }),
        );
        row(
          "",
          checkbox(
            "Groß-/Kleinschreibung ignorieren",
            !!rule.ignoreCase,
            (value) => {
              rule.ignoreCase = value;
              syncJSON();
            },
          ),
        );
        break;
      case "case":
        row(
          "Schreibweise",
          select(
            schema.modes,
            rule.mode || "title",
            (value) => {
              rule.mode = value;
              syncJSON();
            },
            "Schreibweise",
          ),
        );
        row(
          "Kleine Wörter",
          input(
            (rule.smallWords || []).join(", "),
            (value) => {
              rule.smallWords = value
                .split(",")
                .map((item) => item.trim())
                .filter(Boolean);
            },
            "Kleine Wörter",
          ),
        );
        break;
      case "number":
        row(
          "Sortieren nach",
          input(
            rule.sortBy || "filename",
            (value) => {
              rule.sortBy = value;
            },
            "Sortieren nach",
          ),
        );
        row(
          "Beginn",
          input(
            rule.start ?? 1,
            (value) => {
              rule.start = value;
            },
            "Beginn",
            "number",
          ),
        );
        row(
          "Mindestbreite",
          input(
            rule.width ?? 1,
            (value) => {
              rule.width = value;
            },
            "Mindestbreite",
            "number",
          ),
        );
        row(
          "",
          checkbox("Gesamtzahl anhängen", !!rule.total, (value) => {
            rule.total = value;
            syncJSON();
          }),
        );
        break;
    }
    const condition = checkbox("Nur wenn …", !!rule.when, (enabled) => {
      if (enabled) rule.when = { field: "TITLE", is: "notEmpty" };
      else delete rule.when;
      redraw();
    });
    form.append(fields, node("div", { class: "spaced" }, condition));
    if (rule.when) {
      const value = rule.when;
      form.append(
        node(
          "div",
          { class: "fields" },
          node("label", {}, t("Feld")),
          input(
            value.field,
            (next) => {
              value.field = next;
            },
            "Bedingungsfeld",
          ),
          node("label", {}, t("Bedingung")),
          select(
            schema.tests,
            value.is,
            (next) => {
              value.is = next;
              redraw();
            },
            "Bedingung",
          ),
          ...(["empty", "notEmpty"].includes(value.is)
            ? []
            : [
                node("label", {}, t("Vergleichswert")),
                input(
                  value.value,
                  (next) => {
                    value.value = next;
                  },
                  "Vergleichswert",
                ),
              ]),
        ),
      );
      form.append(
        node(
          "div",
          { class: "spaced" },
          checkbox(
            "Groß-/Kleinschreibung ignorieren",
            !!value.ignoreCase,
            (next) => {
              value.ignoreCase = next;
              syncJSON();
            },
          ),
        ),
      );
    }
    form.append(
      node(
        "div",
        { class: "row spaced" },
        button(
          "Nach oben",
          () => {
            if (selected > 0) {
              [document.rules[selected - 1], document.rules[selected]] = [
                document.rules[selected],
                document.rules[selected - 1],
              ];
              selected--;
              redraw();
            }
          },
          { disabled: selected === 0 },
        ),
        button(
          "Nach unten",
          () => {
            if (selected < document.rules.length - 1) {
              [document.rules[selected + 1], document.rules[selected]] = [
                document.rules[selected],
                document.rules[selected + 1],
              ];
              selected++;
              redraw();
            }
          },
          { disabled: selected === document.rules.length - 1 },
        ),
        button(
          "Regel entfernen",
          () => {
            document.rules.splice(selected, 1);
            redraw();
          },
          { class: "danger" },
        ),
      ),
    );
    syncJSON();
  }
  const template = select(
    schema.templates,
    schema.templates[0].id,
    (id) => {
      document = structuredClone(
        schema.templates.find((item) => item.id === id).document,
      );
      selected = 0;
      redraw();
    },
    "Vorlage",
  );
  const controls = node(
    "div",
    { class: "row spaced" },
    template,
    button("Regel hinzufügen", () => {
      document.rules.push({ action: "trim", field: "*" });
      selected = document.rules.length - 1;
      redraw();
    }),
    button(
      "Laden …",
      safe(async () => {
        const [source] = await choose("archive");
        if (source) {
          document = JSON.parse(await request("readRules", { source }));
          selected = 0;
          redraw();
        }
      }),
    ),
    button(
      "Speichern …",
      safe(async () => {
        const [destination] = await choose("save", "rules.json");
        if (destination)
          await act("saveRules", { document, destination }, false);
      }),
    ),
  );
  const inspect = button(
    "Vorschau",
    safe(async () => {
      await enqueue(flush);
      const plans = await request("rulesPreview", { document });
      const table = node(
        "table",
        {},
        node(
          "thead",
          {},
          node(
            "tr",
            {},
            ...["Datei", "Feld", "Bisher", "Neu"].map((title) =>
              node("th", {}, t(title)),
            ),
          ),
        ),
      );
      const body = node("tbody");
      for (const plan of plans)
        for (const change of plan.changes)
          body.append(
            node(
              "tr",
              {},
              node("td", {}, plan.path.split("/").pop()),
              node("td", {}, change.field),
              node(
                "td",
                {},
                change.oldValues
                  ? JSON.stringify(change.oldValues)
                  : change.old,
              ),
              node(
                "td",
                {},
                change.newValues
                  ? JSON.stringify(change.newValues)
                  : change.new,
              ),
            ),
          );
      table.append(body);
      preview.replaceChildren(table);
      if (!plans.length)
        preview.append(node("p", { class: "notice" }, t("Keine Änderungen")));
    }),
  );
  const advancedGroup = node(
    "details",
    {},
    node("summary", {}, t("JSON bearbeiten")),
    advanced,
    button(
      "JSON übernehmen",
      safe(async () => {
        const parsed = JSON.parse(advanced.value);
        await request("rulesPreview", { document: parsed });
        document = parsed;
        selected = 0;
        redraw();
      }),
    ),
  );
  redraw();
  const result = await modal(
    "Regeln anwenden …",
    node(
      "div",
      {},
      controls,
      node("div", { class: "rule-layout" }, list, form),
      error,
      inspect,
      preview,
      advancedGroup,
    ),
    [
      { title: "Abbrechen", value: false },
      { title: "Anwenden und speichern", value: true, primary: true },
    ],
  );
  if (result === true) await act("rulesApply", { document });
}
