#!/usr/bin/env python3
"""Echte Tauri-/WebKit-GUI im isolierten Linux-Display prüfen."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from selenium import webdriver
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.remote.remote_connection import RemoteConnection


def review_linux_frontend(driver, wait, media_call, work, media, english):
    import gi

    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi, GLib

    Atspi.init()

    def text(german, translated):
        return translated if english else german

    def xdotool(*args):
        return subprocess.check_output(['xdotool', *args], text=True, timeout=5)

    def menu_item(name):
        def find(item):
            role = item.get_role()
            if role in (Atspi.Role.MENU, Atspi.Role.MENU_ITEM):
                if item.get_name() == name and item.get_state_set().contains(Atspi.StateType.SHOWING):
                    bounds = item.get_extents(Atspi.CoordType.SCREEN)
                    if bounds.width > 0 and bounds.height > 0:
                        return bounds
            if role in (Atspi.Role.DESKTOP_FRAME, Atspi.Role.APPLICATION, Atspi.Role.FRAME,
                        Atspi.Role.PANEL, Atspi.Role.FILLER, Atspi.Role.MENU_BAR,
                        Atspi.Role.MENU, Atspi.Role.POPUP_MENU):
                for index in range(item.get_child_count()):
                    child = item.get_child_at_index(index)
                    if child is not None and (found := find(child)):
                        return found
            return None

        try:
            return find(Atspi.get_desktop(0))
        except GLib.Error:
            return None

    def click_menu(name):
        bounds = wait.until(lambda _: menu_item(name), f'GTK-Menüeintrag fehlt: {name}')
        xdotool('mousemove', str(bounds.x + bounds.width // 2),
                str(bounds.y + bounds.height // 2), 'click', '1')

    def dialog(title):
        actual = wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, 'dialog[open] #dialog-title'))[0].text
        assert actual == title, (actual, title)

    def dialog_button(german, translated):
        driver.find_element(By.XPATH, f'//dialog[@open]//button[normalize-space()="{text(german, translated)}"]').click()

    def screenshot(name):
        driver.execute_async_script('const done=arguments[arguments.length-1]; requestAnimationFrame(()=>requestAnimationFrame(done));')
        driver.save_screenshot(str(work / name))

    def discard():
        click_menu(text('Bearbeiten', 'Edit'))
        click_menu(text('Änderungen verwerfen …', 'Discard Edits…'))
        dialog(text('Änderungen verwerfen?', 'Discard edits?'))

    start_status = driver.find_element(By.ID, 'status').get_attribute('textContent')
    screenshot('initial-status.png')
    original = media.read_bytes()
    media_call('open', {'paths': [str(media)]})
    driver.refresh()
    row = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, '.file-row'))
    title_selector = f'input[aria-label="{text("Titel", "Title")}"]'
    title = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, title_selector))
    assert title.get_attribute('value') == 'Signal'
    title.clear()
    title.send_keys('Ungespeicherter Titel')
    wait.until(lambda d: 'dirty' in d.find_element(By.CSS_SELECTOR, '.file-row').get_attribute('class'))
    discard()
    assert driver.find_element(By.CSS_SELECTOR, '.file-row').id == row.id
    screenshot('discard-confirmation.png')
    dialog_button('Abbrechen', 'Cancel')
    assert title.get_attribute('value') == 'Ungespeicherter Titel'
    assert media_call('entry', {'path': str(media)})['dirty']
    discard()
    dialog_button('Verwerfen', 'Discard')
    wait.until(lambda d: d.execute_script('return document.querySelector(arguments[0])?.value', title_selector) == 'Signal')
    assert not media_call('entry', {'path': str(media)})['dirty']
    assert not driver.find_element(By.ID, 'save').is_enabled()
    assert media.read_bytes() == original

    other = work / 'Zweites Signal.mp3'
    other.write_bytes(original)
    media_call('open', {'paths': [str(other)]})
    driver.refresh()
    wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, '.file-row')) == 2)
    rows = driver.find_elements(By.CSS_SELECTOR, '.file-row')
    rows[0].click()
    ActionChains(driver).key_down(Keys.CONTROL).click(rows[1]).key_up(Keys.CONTROL).perform()
    wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '#editor .batch-note'))
    batch_title = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, title_selector))
    batch_title.clear()
    batch_title.send_keys('Entwurf für beide Dateien')
    assert not media_call('state', {})['dirty']
    discard()
    dialog_button('Verwerfen', 'Discard')
    wait.until(lambda d: d.execute_script('return document.querySelector(arguments[0])?.value', title_selector) == 'Signal')
    assert not driver.find_element(By.ID, 'save').is_enabled()
    assert not media_call('state', {})['dirty']
    assert media.read_bytes() == other.read_bytes() == original
    media_call('remove', {'paths': [str(other)]})
    driver.refresh()
    wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, '.file-row')) == 1)

    assert start_status == text('Dateien oder Ordner hierher ziehen', 'Drop files or folders here'), start_status
    assert driver.execute_script('return document.documentElement.lang') == text('de', 'en')
    for selector, attribute, german, translated in [
        ('#sidebar-toggle', 'title', 'Dateiliste', 'File list'),
        ('#search', 'aria-label', 'Dateien suchen', 'Search files'),
        ('#file-list', 'aria-label', 'Geöffnete Dateien', 'Open files'),
        ('#tabs', 'aria-label', 'Ansichten', 'Views'),
        ('#settings', 'title', 'Einstellungen', 'Settings'),
        ('#settings', 'aria-label', 'Einstellungen', 'Settings'),
        ('#new-window', 'aria-label', 'Neues Fenster', 'New Window'),
    ]:
        assert driver.find_element(By.CSS_SELECTOR, selector).get_attribute(attribute) == text(german, translated)
    assert driver.find_element(By.ID, 'open-folder').text == text('Ordner …', 'Folder …')
    assert driver.find_element(By.CSS_SELECTOR, '#kind option[value="invoice"]').get_attribute('textContent') == text('E-Rechnungen', 'E-invoices')

    window_id = xdotool('search', '--onlyvisible', '--name', '^Tag Explosion$').splitlines()[0]
    for width, height in [(1100, 800), (760, 500)]:
        xdotool('windowsize', '--sync', window_id, str(width), str(height))
        wait.until(lambda d: d.execute_script('return innerWidth') == width)
        sizes = driver.execute_script('''
          const canvas = document.createElement('canvas').getContext('2d');
          return ['search', 'kind', 'sort'].map(id => {
            const control = document.getElementById(id);
            const style = getComputedStyle(control);
            canvas.font = style.fontSize + ' ' + style.fontFamily;
            const captions = control.options
              ? Array.from(control.options, option => option.text)
              : [control.placeholder];
            const caption = Math.max(...captions.map(text => canvas.measureText(text).width));
            const inset = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
            const border = parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth);
            const arrow = control.options ? 22 : 0;
            return {id, width: control.offsetWidth, needed: Math.ceil(caption + inset + border + arrow)};
          });
        ''')
        assert all(size['width'] >= size['needed'] for size in sizes), (width, sizes)
        if width == 760:
            cover_buttons_fit = driver.execute_script('''
              const row = document.querySelector('.cover-block .row');
              const {left, right} = row.getBoundingClientRect();
              const buttons = [...row.querySelectorAll('button')];
              return buttons.length > 0 && buttons.every(button => {
                const bounds = button.getBoundingClientRect();
                return bounds.left >= left && bounds.right <= right;
              });
            ''')
            assert cover_buttons_fit, 'Cover-Schaltflächen ragen aus ihrer Gruppe'
        screenshot(f'sidebar-{width}.png')
    xdotool('windowsize', '--sync', window_id, '1100', '800')
    wait.until(lambda d: d.execute_script('return innerWidth') == 1100)

    ActionChains(driver).key_down(Keys.CONTROL).send_keys(',').key_up(Keys.CONTROL).perform()
    dialog(text('Einstellungen', 'Settings'))
    labels = [label.text for label in driver.find_elements(By.CSS_SELECTOR, '#dialog-content label')]
    assert text('Vor jeder Änderung im Papierkorb sichern', 'Copy originals to the trash before every change') in labels
    assert text('Bild-Metadaten in XMP-Sidecar schreiben', 'Write image metadata to an XMP sidecar') in labels
    screenshot('keyboard-settings.png')
    dialog_button('Schließen', 'Close')

    folder = work / 'playlist.v1'
    folder.mkdir()
    sibling = folder / 'export.m3u8'
    sibling.write_bytes(b'vorhandene Datei')

    def native_save(destination):
        ActionChains(driver).context_click(driver.find_element(By.CSS_SELECTOR, '.file-row')).perform()
        dialog(text('Werkzeuge', 'Tools'))
        dialog_button('Playlist exportieren …', 'Export Playlist …')

        def visible_chooser(_):
            result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^(Save|Speichern)( File)?$'],
                                    capture_output=True, text=True, timeout=5)
            return result.stdout.splitlines()[0] if result.returncode == 0 else None

        chooser = wait.until(visible_chooser)
        xdotool('windowfocus', '--sync', chooser, 'key', 'ctrl+a')
        xdotool('type', '--clearmodifiers', str(destination))
        xdotool('key', 'Return')
        wait.until(lambda _: not visible_chooser(None))

    for basename in ('export', '.playlist'):
        destination = folder / basename
        native_save(destination)
        wait.until(lambda _: destination.exists())
        assert destination.read_text().startswith('#EXTM3U\n')
    assert sibling.read_bytes() == b'vorhandene Datei'
    destination = folder / 'export.PLS'
    native_save(destination)
    wait.until(lambda _: destination.exists())
    assert destination.read_text().startswith('[playlist]\n')
    destination = folder / 'export.txt'
    native_save(destination)
    dialog(text('Hinweis', 'Notice'))
    assert driver.find_element(By.ID, 'dialog-content').text == text(
        'Für Playlists sind die Endungen .m3u, .m3u8, .pls und .xspf verfügbar.',
        'Use .m3u, .m3u8, .pls, or .xspf for playlists.',
    )
    assert not destination.exists()
    dialog_button('Schließen', 'Close')
    print('Linux-GUI: natives Verwerfen/Abbrechen (Einzel- und Stapelentwurf), Dateibytes, stabile Listenzeile, lokalisierte Attribute und native Playlist-Ziele geprüft.')


def review_regressions(driver, wait, media_call, work):
    # Eigene MP3s unterstützen sowohl CHAP als auch SYLT; keine Imports oder
    # Backend-edits ersetzen die zu prüfenden Hinzufügen-/Eingabe-Callbacks.
    fixtures = Path(tempfile.mkdtemp(prefix='review-', dir=work))
    audio = fixtures / 'Kapitel-Lyrics.mp3'
    other = fixtures / 'Auswahlwechsel.mp3'
    subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'sine=duration=2', str(audio)], check=True, timeout=15)
    shutil.copyfile(audio, other)
    nfos = [fixtures / 'Film-1.nfo', fixtures / 'Film-2.nfo']
    for index, path in enumerate(nfos):
        path.write_text(f'<movie><title>Review {index}</title><rating>8</rating><reviewFixture>bleibt</reviewFixture></movie>', encoding='utf-8')
    media_call('open', {'paths': list(map(str, [audio, other, *nfos]))})
    driver.refresh()
    wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, '.file-row')) >= 4)

    def entry(path):
        return media_call('entry', {'path': str(path)})

    def select_path(path, additional=False, expected=None):
        previous = driver.find_elements(By.CSS_SELECTOR, '#editor .editor-content')
        row = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, '.file-row[data-path=' + json.dumps(str(path)) + ']'))
        if additional:
            ActionChains(driver).key_down(Keys.CONTROL).click(row).key_up(Keys.CONTROL).perform()
        else:
            row.click()
        selected = set(map(str, expected or [path]))
        # Nur lesen: Erst der echte Auswahlklick darf flush/select auslösen.
        wait.until(lambda d: set(media_call('state', {})['selection']) == selected)
        if previous:
            # Auch ein Klick auf die bereits ausgewählte Datei rendert neu.
            # Nicht versehentlich Controls des alten Editors weiterbenutzen.
            wait.until(lambda d: d.find_element(By.CSS_SELECTOR, '#editor .editor-content').id != previous[0].id)
        if len(selected) == 1:
            wait.until(lambda d: d.find_element(By.ID, 'window-subtitle').get_attribute('textContent') == path.name)
        else:
            wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '#editor .batch-note'))
        assert not driver.find_elements(By.CSS_SELECTOR, 'dialog[open]'), driver.page_source

    def group(german, english):
        return wait.until(lambda d: d.find_element(By.XPATH,
            f'//div[@id="editor"]//h3[normalize-space()="{german}" or normalize-space()="{english}"]/following-sibling::section[1]'))

    def enter(field, value):
        field.click()
        field.send_keys(Keys.CONTROL, 'a')
        field.send_keys(Keys.BACKSPACE)
        if value:
            field.send_keys(value)

    def save(paths):
        wait.until(lambda d: d.find_element(By.ID, 'save').is_enabled())
        driver.find_element(By.ID, 'save').click()
        wait.until(lambda d: d.find_element(By.ID, 'save').get_attribute('disabled'))
        assert not driver.find_elements(By.CSS_SELECTOR, 'dialog[open]'), driver.page_source
        state = media_call('state', {})
        assert not state['busy'] and not state.get('alert'), state
        for path in paths:
            assert entry(path)['dirty'] is False, entry(path)

    def reopen(paths):
        # Nach dem Speichern neu vom Dateisystem lesen, nicht nur draft oder
        # den zuvor editierten FileEntry-Puffer als Read-back ausgeben.
        media_call('remove', {'paths': list(map(str, paths))})
        media_call('open', {'paths': list(map(str, paths))})
        driver.refresh()
        wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.file-row'))

    initial = entry(audio)
    if not initial.get('supportsChapters') or not initial.get('supportsSyncedLyrics'):
        raise RuntimeError('Umgebungsgrenze: Diese Engine unterstützt CHAP/SYLT im erzeugten MP3 nicht; GUI-Regressionen nicht vollständig geprüft.')
    assert initial['chapters'] == [] and initial['syncedLyrics'] == [], initial
    select_path(audio)
    chapters = group('Kapitel', 'Chapters')
    chapters.find_element(By.XPATH, './/button[normalize-space()="Hinzufügen" or normalize-space()="Add"]').click()
    # Sofortiger Auswahlwechsel prüft den produktiven flush auch ohne Save.
    select_path(other)
    assert entry(audio)['chapters'] == [{'title': '', 'start': 0, 'end': 0}], entry(audio)
    select_path(audio)
    chapters = group('Kapitel', 'Chapters')
    enter(chapters.find_element(By.CSS_SELECTOR, 'input[aria-label="Titel"], input[aria-label="Title"]'), 'Erstes Kapitel')
    enter(chapters.find_element(By.CSS_SELECTOR, 'input[aria-label="end"]'), '1000')
    save([audio])
    reopen([audio])
    assert entry(audio)['chapters'] == [{'title': 'Erstes Kapitel', 'start': 0, 'end': 1000}], entry(audio)

    select_path(audio)
    lyrics = group('Synchronisierte Liedtexte', 'Synchronized lyrics')
    lyrics.find_element(By.XPATH, './/button[normalize-space()="Hinzufügen" or normalize-space()="Add"]').click()
    select_path(other)
    assert entry(audio)['syncedLyrics'] == [{'time': 0, 'text': ''}], entry(audio)
    select_path(audio)
    lyrics = group('Synchronisierte Liedtexte', 'Synchronized lyrics')
    enter(lyrics.find_element(By.CSS_SELECTOR, 'input[aria-label="time"]'), '200')
    enter(lyrics.find_element(By.CSS_SELECTOR, 'textarea[aria-label="Text"]'), 'Erste Liedtextzeile')
    save([audio])
    reopen([audio])
    assert entry(audio)['syncedLyrics'] == [{'time': 200, 'text': 'Erste Liedtextzeile'}], entry(audio)
    assert entry(audio)['chapters'] == [{'title': 'Erstes Kapitel', 'start': 0, 'end': 1000}], entry(audio)

    select_path(audio)
    for german, english, filename in [('Kapitel', 'Chapters', 'review-chapter.png'), ('Synchronisierte Liedtexte', 'Synchronized lyrics', 'review-lyrics.png')]:
        driver.execute_script("arguments[0].scrollIntoView({block:'center'})", group(german, english))
        driver.execute_async_script('const done=arguments[arguments.length-1]; requestAnimationFrame(()=>requestAnimationFrame(done));')
        driver.save_screenshot(str(work / filename))

    def select_nfos():
        select_path(nfos[0])
        select_path(nfos[1], additional=True, expected=nfos)
        return wait.until(lambda d: d.find_element(By.CSS_SELECTOR, '#editor input[aria-label="Bewertung"], #editor input[aria-label="Rating"]'))

    for value in ('7.50', ''):
        rating = select_nfos()
        enter(rating, value)
        if value:
            # Der sichtbare Übernehmen-Button läuft ebenfalls über flush.
            driver.find_element(By.XPATH, '//div[@id="editor"]//button[normalize-space()="Änderungen übernehmen" or normalize-space()="Apply changes"]').click()
            wait.until(lambda d: all(entry(path)['fields']['rating'] == value for path in nfos))
        else:
            # Ein leerer String darf weder null werden noch den Wechsel sperren.
            select_path(other)
        for path in nfos:
            result = entry(path)['fields']['rating']
            assert isinstance(result, str) and result == value, (path, result)
        if not value:
            select_nfos()
        driver.save_screenshot(str(work / ('review-rating-' + ('empty' if not value else 'value') + '.png')))
        save(nfos)
        reopen(nfos)
        for path in nfos:
            assert entry(path)['fields']['rating'] == value, entry(path)
            tree = ET.parse(path)
            assert tree.findtext('rating', default='') == value, path.read_text()
            assert tree.findtext('reviewFixture') == 'bleibt', path.read_text()
    driver.save_screenshot(str(work / 'review-regressions.png'))
    print('GUI-Regressionen: erste Kapitel-/SYLT-Zeile per Hinzufügen, Auswahlwechsel-flush, Eingabe und Speichern; NFO-Stapelbewertung als String 7.50 und Leerstring, Übernehmen/Wechsel, Backend-Neuöffnung und XML-Read-back bestanden.')


root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=root / 'Linux/target/debug/tag-explosion-linux')
parser.add_argument('--engine', type=Path)
parser.add_argument('--validate', action='store_true')
parser.add_argument('--exiftool', type=Path, help='Unabhängiges Prüfwerkzeug, falls es außerhalb des Desktop-PATH liegt')
parser.add_argument('--basic-fixture', type=Path, help='Native Grundprüfung ohne optionale Systemwerkzeuge')
review = parser.add_mutually_exclusive_group()
review.add_argument('--review-regressions', action='store_true', help='Nach der Audio-Grundprüfung nur Kapitel/SYLT und NFO-Stapelbewertung prüfen (Linux, ffmpeg)')
review.add_argument('--review-linux-frontend', action='store_true', help='Natives GTK-Menü, Playlist und zugängliche WebKit-Beschriftungen prüfen (X11)')
parser.add_argument('--frontend-language', choices=['de', 'en'], default='de', help='Sprache für --review-linux-frontend')
parser.add_argument('--work-dir', type=Path, default=root / '.build/linux-gui-smoke')
parser.add_argument('--driver', type=Path, default=root / '.build/driver/bin/tauri-driver')
args = parser.parse_args()
if args.review_regressions and sys.platform != 'linux':
    parser.exit(2, 'Umgebungsgrenze: GUI-Regressionen benötigen Linux/Tauri/WebKit; nicht ausgeführt.\n')
if args.review_regressions and not shutil.which('ffmpeg'):
    parser.exit(2, 'Umgebungsgrenze: ffmpeg für eigene Review-Fixtures fehlt; nicht ausgeführt.\n')
exiftool = str(args.exiftool) if args.exiftool else "exiftool"
work = args.work_dir.resolve()
work.mkdir(parents=True, exist_ok=True)
media = work / 'Signal.mp3'
if args.basic_fixture:
    shutil.copyfile(args.basic_fixture, media)
else:
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', '-metadata', 'title=Signal', '-metadata', 'artist=Beispiel', str(media)], check=True)
for folder in ['home', 'config', 'data', 'cache']: (work / folder).mkdir(exist_ok=True)
environment = dict(os.environ, LANG='de_DE.UTF-8', HOME=str(work / 'home'), XDG_CONFIG_HOME=str(work / 'config'), XDG_DATA_HOME=str(work / 'data'), XDG_CACHE_HOME=str(work / 'cache'))
if args.review_linux_frontend:
    if args.frontend_language == 'en':
        environment['LANG'] = 'C.UTF-8'
    for name in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE'):
        environment.pop(name, None)
    if not shutil.which('xdotool') or environment.get('GDK_BACKEND') == 'wayland':
        parser.exit(2, 'Die GTK-Menüprüfung benötigt X11 und xdotool.\n')
if args.engine: environment['TAGX_ENGINE'] = str(args.engine.resolve())
elif args.app == root / 'Linux/target/debug/tag-explosion-linux': environment['TAGX_ENGINE'] = str(root / '.build/debug/tagx-engine')
driver_process = subprocess.Popen([str(args.driver), '--port', '4444'], env=environment, stdout=(work / 'driver.log').open('w'), stderr=subprocess.STDOUT)
driver = None
try:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen('http://127.0.0.1:4444/status', timeout=1)
            break
        except OSError:
            if driver_process.poll() is not None:
                raise RuntimeError((work / 'driver.log').read_text())
            time.sleep(.15)
    options = webdriver.common.options.ArgOptions()
    options.set_capability('tauri:options', {'application': str(args.app)})
    options.set_capability('timeouts', {'implicit': 0, 'pageLoad': 30000, 'script': 30000})
    try:
        from selenium.webdriver.remote.client_config import ClientConfig
    except ImportError:
        RemoteConnection.set_timeout(40)
        connection = 'http://127.0.0.1:4444'
    else:
        connection = RemoteConnection(client_config=ClientConfig(remote_server_addr='http://127.0.0.1:4444', timeout=40))
    driver = webdriver.Remote(command_executor=connection, options=options)
    wait = WebDriverWait(driver, 20)
    wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.empty h1'))

    def media_call(method, params):
        result = driver.execute_async_script("const done=arguments[arguments.length-1]; window.__TAURI__.core.invoke('media',{method:arguments[0],params:arguments[1]}).then(done).catch(error=>done({error:String(error)}));", method, params)
        assert not isinstance(result, dict) or not result.get('error'), result
        return result

    if args.review_linux_frontend:
        review_linux_frontend(driver, wait, media_call, work, media, args.frontend_language == 'en')
        raise SystemExit(0)

    # Native Dateipanel/Drop bekommen getrennte Interaktionsprüfungen. Hier
    # wird der echte produktive Frontend-Aufruf benutzt, kein Swift-Direktaufruf.
    driver.execute_async_script('''const done=arguments[arguments.length-1]; window.__TAURI__.core.invoke('media',{method:'open',params:{paths:[arguments[0]]}}).then(done).catch(error=>done({error:String(error)}));''', str(media))
    driver.refresh()
    wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.file-row'))
    title = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, 'input[aria-label="Titel"], input[aria-label="Title"]'))
    assert title.get_attribute('value') == 'Signal'
    title.clear()
    title.send_keys('<img src=x onerror="window.untrustedTagExecuted=true">')
    driver.find_element(By.ID, 'save').click()
    wait.until(lambda d: d.find_element(By.ID, 'save').get_attribute('disabled'))
    assert driver.execute_script('return window.untrustedTagExecuted === true') is False
    assert not driver.find_elements(By.CSS_SELECTOR, '#editor img[src="x"]')
    if args.basic_fixture:
        driver.save_screenshot(str(work / 'native-basic.png'))
        result = media_call('entry', {'path': str(media)})
        assert any(item['key'] == 'TITLE' and item['value'].startswith('<img src=x') for item in result['properties'])
        print('GUI: nativer Mint-AppImage-Start, Audioformular, sicheres HTML und Speichern mit Read-back bestanden.')
        if not args.review_regressions:
            raise SystemExit(0)
    else:
        # Speichern muss auf der Platte angekommen sein, einschließlich Read-back.
        result = subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags=title', '-of', 'json', str(media)], text=True)
        assert json.loads(result)['format']['tags']['title'].startswith('<img src=x')
    if args.review_regressions:
        review_regressions(driver, wait, media_call, work)
        raise SystemExit(0)
    driver.find_element(By.XPATH, '//div[@id="tabs"]/button[contains(text(),"Technik")]').click()
    wait.until(lambda d: 'General' in d.find_element(By.ID, 'editor').text)
    assert 'Format' in driver.find_element(By.ID, 'editor').text
    driver.find_element(By.XPATH, '//div[@id="tabs"]/button[text()="Tags"]').click()
    wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, 'input[aria-label="Titel"], input[aria-label="Title"]'))
    driver.execute_script("localStorage.setItem('theme','light'); document.documentElement.dataset.theme='light'")
    driver.execute_async_script('const done=arguments[arguments.length-1]; requestAnimationFrame(()=>requestAnimationFrame(done));')
    driver.save_screenshot(str(work / 'audio-light.png'))
    driver.execute_script("document.documentElement.dataset.theme='dark'")
    driver.execute_async_script('const done=arguments[arguments.length-1]; requestAnimationFrame(()=>requestAnimationFrame(done));')
    driver.save_screenshot(str(work / 'audio-dark.png'))
    driver.execute_script("document.documentElement.dataset.theme='light'")
    def select_file(path):
        media_call('open', {'paths': [str(path)]})
        media_call('select', {'paths': [str(path)]})
        driver.refresh()
        wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.file-row[aria-selected="true"]'))
    def set_title(value):
        field = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, 'input[aria-label="Titel"], input[aria-label="Title"]'))
        field.clear(); field.send_keys(value)
        driver.find_element(By.ID, 'save').click()
        wait.until(lambda d: d.find_element(By.ID, 'save').get_attribute('disabled'))
        assert not driver.find_elements(By.CSS_SELECTOR, 'dialog[open]'), driver.page_source
    # Bild: Der produktive ExifTool-Schreibweg muss die Benutzeränderung lesen.
    picture = work / 'Bild.png'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=skyblue:s=640x480', '-frames:v', '1', '-threads', '1', str(picture)], check=True)
    select_file(picture); set_title('Bildtitel geprüft')
    wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.image-preview img') and d.find_element(By.CSS_SELECTOR, '.image-preview img').get_property('naturalWidth') > 0)
    assert 'Bildtitel geprüft' in subprocess.check_output([exiftool, '-s3', '-XMP-dc:Title', str(picture)], text=True)
    driver.save_screenshot(str(work / 'image.png'))
    # EPUB nativ: Text und ZIP-Struktur bleiben gemeinsam nutzbar.
    ebook = work / 'Buch.epub'
    with zipfile.ZipFile(ebook, 'w') as package:
        package.writestr('mimetype', 'application/epub+zip')
        package.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        package.writestr('content.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:tagx-test</dc:identifier><dc:title>Buch</dc:title><dc:language>de</dc:language></metadata><manifest><item id="page" href="page.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="page"/></spine></package>')
        package.writestr('page.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Test</title></head><body>Unveränderter Inhalt</body></html>')
    select_file(ebook); set_title('Buchtitel geprüft')
    with zipfile.ZipFile(ebook) as package:
        assert 'Buchtitel geprüft' in package.read('content.opf').decode()
        assert 'Unveränderter Inhalt' in package.read('page.xhtml').decode()
    driver.save_screenshot(str(work / 'ebook.png'))
    note = work / 'Notiz.md'; note.write_text('---\ntitle: Notiz\nauthor: Beispiel\n---\n\nGeschützter Dokumentinhalt.\n')
    select_file(note); set_title('Notiz geprüft')
    assert 'Notiz geprüft' in note.read_text() and 'Geschützter Dokumentinhalt.' in note.read_text()
    subtitle = work / 'Film.de.vtt'; subtitle.write_text('WEBVTT Film\nLanguage: de\n\n00:00:00.000 --> 00:00:01.000\nUntertitel bleibt erhalten.\n')
    select_file(subtitle); set_title('Untertitel geprüft')
    driver.find_element(By.XPATH, '//button[contains(text(),"Untertitel verschieben")]').click()
    shift = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, 'dialog[open] input[type=number]'))
    shift.clear(); shift.send_keys('1.5')
    driver.find_element(By.XPATH, '//div[@id="dialog-actions"]/button[contains(text(),"Verschieben")]').click()
    wait.until(lambda d: not d.find_elements(By.CSS_SELECTOR, 'dialog[open]'))
    wait.until(lambda d: '00:00:01.500' in subtitle.read_text())
    assert 'WEBVTT Untertitel geprüft' in subtitle.read_text() and 'Untertitel bleibt erhalten.' in subtitle.read_text()
    invoice = work / 'Rechnung.xml'
    invoice.write_text('<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2" xmlns:b="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"><b:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</b:CustomizationID><b:ID>GUI-RE-1</b:ID></Invoice>')
    select_file(invoice)
    wait.until(lambda d: 'BT-1' in d.find_element(By.ID, 'editor').text)
    assert 'GUI-RE-1' in driver.find_element(By.ID, 'editor').text
    driver.save_screenshot(str(work / 'invoice.png'))
    if args.validate:
        driver.find_element(By.XPATH, '//button[contains(text(),"Lokal prüfen")]').click()
        wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, 'dialog[open] h3'))
        report = driver.find_element(By.ID, 'dialog-content').text
        assert 'XML-Prüfung fehlgeschlagen' in report and 'XML-Syntax' in report and 'XML-Schema' in report, report
        driver.save_screenshot(str(work / 'validation.png'))
        original = invoice.read_text(); invoice.write_text(original.replace('GUI-RE-1', 'EXTERN-2'))
        wait.until(lambda d: 'Datei verändert' in d.find_element(By.CSS_SELECTOR, 'dialog[open] h3').text)
        driver.find_element(By.XPATH, '//div[@id="dialog-actions"]/button[contains(text(),"Schließen")]').click()

    # Batch-Bearbeitung über die sichtbaren Controls, einschließlich Regeln.
    other = work / '02 - Zweiter Titel.mp3'; shutil.copyfile(media, other)
    media_call('open', {'paths': [str(other)]})
    media_call('select', {'paths': [str(media), str(other)]}); driver.refresh()
    artist = wait.until(lambda d: d.find_element(By.CSS_SELECTOR, 'input[aria-label="Künstler"], input[aria-label="Artist"]'))
    artist.clear(); artist.send_keys('Stapel geprüft')
    driver.find_element(By.ID, 'save').click()
    wait.until(lambda d: d.find_element(By.ID, 'save').get_attribute('disabled'))
    for path in [media, other]:
        tags = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags=artist', '-of', 'json', str(path)]))['format']['tags']
        assert tags['artist'] == 'Stapel geprüft', tags
    driver.save_screenshot(str(work / 'batch.png'))
    driver.find_element(By.XPATH, '//button[contains(text(),"Regeln …")]').click()
    wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.rule-layout'))
    assert driver.find_elements(By.CSS_SELECTOR, '.rule-form select')
    driver.save_screenshot(str(work / 'rules.png'))
    driver.find_element(By.XPATH, '//div[@id="dialog-actions"]/button[contains(text(),"Abbrechen")]').click()
    # GTK-Dateidialog und echte XDND-Ereignisse brauchen einen X11-Testdisplay.
    if shutil.which('xdotool') and environment.get('GDK_BACKEND') != 'wayland':
        panel = work / 'Panel.mp3'; shutil.copyfile(media, panel)
        driver.find_element(By.ID, 'open').click()
        deadline = time.monotonic() + 10
        chooser = None
        while time.monotonic() < deadline:
            found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', 'Open|Öffnen'], capture_output=True, text=True)
            if found.returncode == 0:
                chooser = found.stdout.splitlines()[-1]; break
            time.sleep(.1)
        assert chooser, 'Nativer GTK-Dateidialog fehlt'
        subprocess.run(['import', '-window', 'root', str(work / 'native-dialog.png')], check=True)
        subprocess.run(['xdotool', 'windowfocus', '--sync', chooser, 'key', 'ctrl+l'], check=True)
        time.sleep(.5)
        subprocess.run(['import', '-window', 'root', str(work / 'native-location.png')], check=True)
        subprocess.run(['xdotool', 'type', '--clearmodifiers', '--delay', '1', str(panel)], check=True)
        time.sleep(.3)
        subprocess.run(['import', '-window', 'root', str(work / 'native-typed.png')], check=True)
        subprocess.run(['xdotool', 'key', 'Return'], check=True)
        time.sleep(.7)
        still_open = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Open$|^Öffnen$'], capture_output=True)
        if still_open.returncode == 0: subprocess.run(['xdotool', 'key', 'Return'], check=True)
        wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.file-row[data-path="' + str(panel) + '"]'))
        dropped = work / 'Drop.mp3'; shutil.copyfile(media, dropped)
        source = subprocess.Popen(['python3', str(root / 'Tests/Linux/drag_source.py'), str(dropped)], env=environment)
        try:
            time.sleep(.5)
            subprocess.run(['xdotool', 'mousemove', '1190', '880', 'mousedown', '1', 'sleep', '.2', 'mousemove', '--sync', '1160', '860', 'sleep', '.2', 'mousemove', '--sync', '800', '400', 'sleep', '.5', 'mouseup', '1'], check=True)
            wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '.file-row[data-path="' + str(dropped) + '"]'))
        finally:
            subprocess.run(['xdotool', 'mouseup', '1'], check=False)
            source.terminate(); source.wait(timeout=5)
        print('GUI: nativer GTK-Dateidialog und echter URI-Datei-Drop bestanden.')
    print('GUI: Audio, Bild, EPUB, Markdown, VTT-Zeitverschiebung und Batch mit unabhängigen Plattenprüfungen; Rechnungsfelder, Regeln und HTML-Inhalt bestanden.')
except Exception:
    if driver:
        driver.save_screenshot(str(work / 'failure.png'))
        (work / 'failure.html').write_text(driver.page_source)
    raise
finally:
    if driver:
        if os.environ.get('APPIMAGE_EXTRACT_AND_RUN') == '1':
            try:
                driver.execute_async_script("const done=arguments[arguments.length-1]; window.__TAURI__.core.invoke('close_window').then(done).catch(done);")
            except Exception:
                pass
        driver.quit()
    driver_process.terminate()
    try:
        driver_process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        driver_process.kill()
        driver_process.wait(timeout=5)
