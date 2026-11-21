export function createFileList(list, onSelect, onMenu) {
  let rows = new Map();
  let order = [];

  return (entries, selection) => {
    const nextRows = new Map();
    const nextOrder = [];
    let orderChanged = entries.length !== order.length;

    for (const entry of entries) {
      const path = entry.path;
      let row = rows.get(path);
      if (!row) {
        const element = document.createElement("div");
        const title = document.createElement("strong");
        const detail = document.createElement("small");
        element.setAttribute("role", "option");
        element.dataset.path = path;
        element.title = path;
        element.onclick = (event) => onSelect(path, event);
        element.oncontextmenu = (event) => {
          event.preventDefault();
          onMenu(path);
        };
        element.append(title, detail);
        row = { element, title, detail };
      }

      const selected = selection.has(path);
      const subtitle = entry.error || entry.subtitle || entry.name;
      const className = `file-row${entry.dirty ? " dirty" : ""}${entry.error ? " error" : ""}`;
      if (row.selected !== selected) {
        row.element.setAttribute("aria-selected", String(selected));
        row.selected = selected;
      }
      if (row.className !== className) {
        row.element.className = className;
        row.className = className;
      }
      if (row.titleText !== entry.title) {
        row.title.textContent = entry.title;
        row.titleText = entry.title;
      }
      if (row.detailText !== subtitle) {
        row.detail.textContent = subtitle;
        row.detailText = subtitle;
      }
      orderChanged ||= path !== order[nextOrder.length];
      nextOrder.push(path);
      nextRows.set(path, row);
    }

    if (orderChanged) {
      const top = list.scrollTop;
      const content = document.createDocumentFragment();
      for (const row of nextRows.values()) content.append(row.element);
      list.replaceChildren(content);
      list.scrollTop = top;
    }
    rows = nextRows;
    order = nextOrder;
  };
}
