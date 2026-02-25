import sqlite3
import serial
import time
import os
import requests
import json
import evdev
from evdev import ecodes
from plexapi.server import PlexServer
import pychromecast

DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')
PLEX_APP_ID = '9AC19493'
WEB_URL = 'http://127.0.0.1:5000'

SCAN_CODES = {
    0: None, 1: u'ESC', 2: u'1', 3: u'2', 4: u'3', 5: u'4', 6: u'5', 7: u'6', 8: u'7', 9: u'8', 10: u'9', 11: u'0',
    12: u'-', 13: u'=', 14: u'BKSP', 15: u'TAB', 16: u'q', 17: u'w', 18: u'e', 19: u'r', 20: u't', 21: u'y', 22: u'u',
    23: u'i', 24: u'o', 25: u'p', 26: u'[', 27: u']', 28: u'CRLF', 29: u'LCTRL', 30: u'a', 31: u's', 32: u'd', 33: u'f',
    34: u'g', 35: u'h', 36: u'j', 37: u'k', 38: u'l', 39: u';', 40: u'\'', 41: u'\`', 42: u'LSHFT', 43: u'\\',
    44: u'z', 45: u'x', 46: u'c', 47: u'v', 48: u'b', 49: u'n', 50: u'm', 51: u',', 52: u'.', 53: u'/', 54: u'RSHFT',
    56: u'LALT', 57: u' ', 100: u'RALT'
}

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=20)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.row_factory = sqlite3.Row
    return conn

def log(msg, source='listener'):
    print(f'[{source.upper()}] {msg}', flush=True)
    try:
        with get_db() as conn:
            conn.execute('INSERT INTO logs (source, message) VALUES (?, ?)', (source, msg))
            conn.commit()
    except Exception as e:
        print(f'Database logging failed: {e}', flush=True)

def post_status_update(message):
    try:
        requests.post(f'{WEB_URL}/publish_status', json={'message': message}, timeout=2)
    except requests.exceptions.RequestException as e:
        log(f'Could not post status update to web UI: {e}')

def get_scanner_settings():
    with get_db() as conn:
        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN ("scanner_mode", "scanner_device")')}
        return settings.get('scanner_mode', 'serial'), settings.get('scanner_device', '/dev/ttyACM0')

def get_plex_settings():
    with get_db() as conn:
        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN ("plex_protocol", "plex_url", "plex_port", "plex_token", "tmdb_api_key")')}
        return settings

def get_plex_server():
    settings = get_plex_settings()
    if not all(k in settings for k in ['plex_protocol', 'plex_url', 'plex_port', 'plex_token']):
        log('Incomplete Plex settings')
        return None
    try:
        plex_url = f"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}"
        return PlexServer(plex_url, settings['plex_token'])
    except Exception as e:
        log(f'Failed to connect to Plex server: {e}')
        return None

def get_media_info_from_db(barcode):
    with get_db() as conn:
        row = conn.execute('SELECT rating_key FROM barcodes WHERE barcode = ?', (barcode,)).fetchone()
        return row['rating_key'] if row else None

def lookup_barcode_on_tmdb(barcode):
    settings = get_plex_settings()
    api_key = settings.get('tmdb_api_key')
    if not api_key: return
    log(f'Barcode not in local DB. Searching TMDB for {barcode}...')
    try:
        search_codes = [barcode, barcode.lstrip('0')]
        for code in set(search_codes):
            url = f'https://api.themoviedb.org/3/find/{code}?external_source=ean&api_key={api_key}'
            response = requests.get(url, timeout=5)
            response.raise_for_status()
            data = response.json()
            results = data.get('movie_results', []) + data.get('tv_results', [])
            if results:
                title = results[0].get('title') or results[0].get('name')
                log(f'Scanned barcode {barcode} is for "{title}", which is not in the Plex library.')
                post_status_update(f'Scanned: "{title}" (Not in Library)')
                return
    except Exception as e:
        log(f'Error querying TMDB: {e}')

def get_selected_target():
    with get_db() as conn:
        row = conn.execute('SELECT value FROM settings WHERE key = "last_client"').fetchone()
        return row['value'] if row else None

def play_media_on_device(rating_key, plex_server, target_device_name):
    try:
        media = plex_server.fetchItem(int(rating_key))
        if not media: 
            log(f'No media found for rating_key {rating_key}')
            return
        post_status_update(f'Playing "{media.title}" on {target_device_name}')
        is_chromecast = False
        try:
            casts, _ = pychromecast.get_listed_chromecasts(friendly_names=[target_device_name])
            if casts: is_chromecast = True
        except Exception: log('Chromecast discovery failed.')
        max_retries = 3
        retry_delay = 3
        for attempt in range(max_retries):
            try:
                if not is_chromecast:
                    log(f'Attempting playback on {target_device_name} (attempt {attempt + 1}/{max_retries})...')
                    client = plex_server.client(target_device_name)
                    client.playMedia(media)
                    log(f'Playback command sent for "{media.title}" to {target_device_name}.')
                else:
                    log(f'Attempting Chromecast playback on {target_device_name} (attempt {attempt + 1}/{max_retries})...')
                    plex_client = None
                    casts[0].wait()
                    target_uuid = str(casts[0].cast_info.uuid).replace('-', '')
                    if casts[0].app_id != '9AC19493':
                        log('Plex app is not running. Launching app...')
                        casts[0].start_app('9AC19493')
                        for _ in range(10):
                            time.sleep(2)
                            try:
                                for c in plex_server.clients():
                                    if c.machineIdentifier == target_uuid: plex_client = c; break
                                if plex_client: break
                            except Exception: pass
                    if not plex_client:
                        for c in plex_server.clients():
                            if c.machineIdentifier == target_uuid: plex_client = c; break
                    if plex_client:
                        client_name = getattr(plex_client, "name", plex_client.title)
                        log(f'UUID match found! Client name is "{client_name}".')
                        plex_client.playMedia(media)
                    else:
                        raise ConnectionError('Could not find a matching Chromecast client on Plex Server after wake-up.')
                return
            except requests.exceptions.ConnectionError as e:
                log(f'Playback failed on attempt {attempt + 1}: Connection refused or failed.')
                if attempt < max_retries - 1:
                    log(f'Retrying in {retry_delay} seconds...')
                    time.sleep(retry_delay)
                else:
                    log('All playback attempts failed.')
            except Exception as e:
                log(f'An unexpected error occurred during playback: {e}')
                return
    except Exception as e: log(f'Top-level playback error: {e}')

def handle_barcode(barcode):
    log(f'Received barcode: {barcode}')
    plex_server = get_plex_server()
    if not plex_server: log('No Plex server connection'); return
    rating_key = get_media_info_from_db(barcode)
    if not rating_key:
        log(f'No media found for barcode: {barcode}')
        lookup_barcode_on_tmdb(barcode)
        return
    try:
        item = plex_server.fetchItem(int(rating_key))
        post_status_update(f'Scanned: {item.title}')
    except Exception as e:
        log(f'Could not fetch item title for {rating_key}: {e}')
        post_status_update(f'Scanned barcode {barcode}')
    target_device = get_selected_target()
    if target_device: play_media_on_device(rating_key, plex_server, target_device)
    else: log('No client selected for playback')

def listen_serial(device_path):
    log(f'Starting SERIAL listener on {device_path}')
    while True:
        try:
            with serial.Serial(device_path, 9600, timeout=1) as ser:
                log(f'Successfully opened serial port {device_path}')
                while True:
                    line = ser.readline().decode('utf-8', errors='ignore').strip()
                    if line: handle_barcode(line)
        except serial.SerialException as e:
            log(f'Serial error on {device_path}: {e}. Retrying in 5 seconds...')
            time.sleep(5)
        except Exception as e:
            log(f'Unexpected error in serial listener: {e}. Retrying in 5 seconds...')
            time.sleep(5)

def listen_hid(device_path):
    log(f'Starting HID listener on {device_path}')
    while True:
        try:
            device = evdev.InputDevice(device_path)
            log(f'Successfully opened HID device {device.name} at {device_path}.')
            barcode = ''
            for event in device.read_loop():
                if event.type == ecodes.EV_KEY and event.value == 1:
                    key = SCAN_CODES.get(event.code)
                    if key == 'CRLF':
                        if barcode: handle_barcode(barcode)
                        barcode = ''
                    elif key and len(key) == 1:
                        barcode += key
        except (IOError, OSError) as e:
            log(f'HID error on {device_path}: {e}. Retrying in 5 seconds...')
            time.sleep(5)
        except Exception as e:
            log(f'Unexpected error in HID listener: {e}. Retrying in 5 seconds...')
            time.sleep(5)

def main():
    log('Starting barcode/NFC listener service...')
    mode, device = get_scanner_settings()
    if mode == 'serial':
        listen_serial(device)
    elif mode == 'hid':
        listen_hid(device)
    else:
        log(f'Unknown scanner mode: {mode}')

if __name__ == '__main__':
    main()

