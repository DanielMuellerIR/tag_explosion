#!/usr/bin/env python3
"""Echte URI-Dateiübertragung an das Tauri-Fenster im isolierten X11-Test."""
from pathlib import Path
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk

window = Gtk.Window(title='TagX Synthetic Drag Source')
window.set_default_size(150, 70)
window.move(1120, 850)
button = Gtk.Button(label='Synthetic file')
button.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [Gtk.TargetEntry.new('text/uri-list', 0, 0)], Gdk.DragAction.COPY)
button.connect('drag-data-get', lambda _widget, _context, selection, _info, _time: selection.set_uris([Path(sys.argv[1]).resolve().as_uri()]))
window.add(button)
window.connect('destroy', Gtk.main_quit)
window.show_all()
Gtk.main()
