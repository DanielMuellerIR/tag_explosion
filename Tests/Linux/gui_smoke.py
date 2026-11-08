#!/usr/bin/env python3
"""Echte Tauri-/WebKit-GUI im isolierten Linux-Display prüfen."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import urllib.request
import zipfile

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.remote.remote_connection import RemoteConnection

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=root / 'Linux/target/debug/tag-explosion-linux')
parser.add_argument('--engine', type=Path)
parser.add_argument('--validate', action='store_true')
parser.add_argument('--exiftool', type=Path, help='Unabhängiges Prüfwerkzeug, falls es außerhalb des Desktop-PATH liegt')
parser.add_argument('--basic-fixture', type=Path, help='Native Grundprüfung ohne optionale Systemwerkzeuge')
parser.add_argument('--work-dir', type=Path, default=root / '.build/linux-gui-smoke')
parser.add_argument('--driver', type=Path, default=root / '.build/driver/bin/tauri-driver')
args = parser.parse_args()
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
        result = driver.execute_async_script("const done=arguments[arguments.length-1]; window.__TAURI__.core.invoke('media',{method:'entry',params:{path:arguments[0]}}).then(done);", str(media))
        assert any(item['key'] == 'TITLE' and item['value'].startswith('<img src=x') for item in result['properties'])
        print('GUI: nativer Mint-AppImage-Start, Audioformular, sicheres HTML und Speichern mit Read-back bestanden.')
        raise SystemExit(0)
    # Speichern muss auf der Platte angekommen sein, einschließlich Read-back.
    result = subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags=title', '-of', 'json', str(media)], text=True)
    assert json.loads(result)['format']['tags']['title'].startswith('<img src=x')
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
    def media_call(method, params):
        result = driver.execute_async_script("const done=arguments[arguments.length-1]; window.__TAURI__.core.invoke('media',{method:arguments[0],params:arguments[1]}).then(done).catch(error=>done({error:String(error)}));", method, params)
        assert not isinstance(result, dict) or not result.get('error'), result
        return result
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
