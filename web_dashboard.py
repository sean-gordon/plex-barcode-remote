import os
import sqlite3
import io
import random
import subprocess
import re
import time
import glob
import json
import signal
import evdev
from flask import Flask, render_template, request, redirect, url_for, send_file, jsonify, flash, session
from flask_sse import sse
from plexapi.server import PlexServer
from plexapi.myplex import MyPlexAccount, MyPlexPinLogin
from PIL import Image, ImageDraw, ImageFont
import barcode
from barcode.writer import ImageWriter
import requests
from serial.tools import list_ports
import pychromecast
from werkzeug.security import generate_password_hash, check_password_hash
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user

DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__)
app.secret_key = os.urandom(24)
app.config['REDIS_URL'] = os.environ.get('REDIS_URL', 'redis://localhost')
app.register_blueprint(sse, url_prefix='/stream')

def init_db():
    with get_db() as conn:
        conn.execute('''CREATE TABLE IF NOT EXISTS barcodes (
            rating_key TEXT PRIMARY KEY NOT NULL,
            barcode TEXT UNIQUE NOT NULL,
            media_type TEXT NOT NULL
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS known_clients (
            name TEXT PRIMARY KEY NOT NULL
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            source TEXT NOT NULL,
            message TEXT NOT NULL
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS media_items (
            rating_key TEXT PRIMARY KEY,
            title TEXT,
            year INTEGER,
            media_type TEXT,
            contentRating TEXT,
            thumb TEXT,
            directors_json TEXT,
            actors_json TEXT,
            genres_json TEXT
        )''')
        conn.commit()

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

class User(UserMixin):
    def __init__(self, id, username, password_hash):
        self.id = id
        self.username = username
        self.password_hash = password_hash

@login_manager.user_loader
def load_user(user_id):
    with get_db() as conn:
        user_row = conn.execute('SELECT * FROM users WHERE id = ?', (user_id,)).fetchone()
        if user_row:
            return User(id=user_row['id'], username=user_row['username'], password_hash=user_row['password_hash'])
    return None

def log(msg, source='web'):
    print(f'[{source.upper()}] {msg}', flush=True)
    try:
        with get_db() as conn:
            conn.execute('INSERT INTO logs (source, message) VALUES (?, ?)', (source, msg))
            conn.commit()
    except Exception as e:
        print(f'Database logging failed: {e}', flush=True)

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=20)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.row_factory = sqlite3.Row
    return conn

def create_default_user():
    with get_db() as conn:
        user = conn.execute('SELECT * FROM users').fetchone()
        if not user:
            log('No user found, creating default Admin user.')
            default_pass_hash = generate_password_hash('Admin')
            conn.execute('INSERT INTO users (username, password_hash) VALUES (?, ?)', ('Admin', default_pass_hash))
            conn.commit()

def get_plex_settings():
    with get_db() as conn:
        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN ("plex_protocol", "plex_url", "plex_port", "plex_token", "tmdb_api_key")')}
        return settings

def get_plex_server():
    settings = get_plex_settings()
    if not all(k in settings for k in ['plex_protocol', "plex_url", "plex_port", "plex_token"]):
        return None
    try:
        if (settings['plex_protocol'] == 'https' and settings['plex_port'] == '443') or (settings['plex_protocol'] == 'http' and settings['plex_port'] == '80'):
            plex_url = f"{settings['plex_protocol']}://{settings['plex_url']}"
        else:
            plex_url = f"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}"
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        session = requests.Session()
        session.verify = False
        return PlexServer(plex_url, settings['plex_token'], session=session)
    except Exception as e:
        log(f'Failed to connect to Plex server: {e}')
        return None

plex = None

def get_hid_devices():
    devices = []
    try:
        for path in glob.glob('/dev/input/event*'):
            try:
                device = evdev.InputDevice(path)
                if evdev.ecodes.EV_KEY in device.capabilities():
                    devices.append({'path': path, 'name': device.name})
            except Exception:
                pass # Ignore devices we can't open
    except Exception as e:
        log(f'Error scanning for HID devices: {e}')
    return devices

def get_or_create_barcode(rating_key, media_type, _depth=0):
    if _depth > 10:
        log(f"Failed to generate unique barcode for {rating_key} after 10 tries")
        return None
    with get_db() as conn:
        row = conn.execute('SELECT barcode FROM barcodes WHERE rating_key = ?', (rating_key,)).fetchone()
        if row: return row['barcode']
        new_code = ''.join(str(random.randint(0, 9)) for _ in range(12))
        try:
            conn.execute('INSERT INTO barcodes (rating_key, barcode, media_type) VALUES (?, ?, ?)', (rating_key, new_code, media_type))
            conn.commit()
        except sqlite3.IntegrityError:
            return get_or_create_barcode(rating_key, media_type, _depth + 1)
        return new_code

def create_fallback_image(error_message):
    img = Image.new('RGB', (300, 400), (255, 255, 255))
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("arial.ttf", 20)
    except IOError:
        font = ImageFont.load_default()
    draw.text((10, 10), f'Error:\n{error_message}', fill=(255,0,0), font=font)
    buf = io.BytesIO()
    img.save(buf, format='JPEG')
    buf.seek(0)
    return buf

@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('index'))
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        with get_db() as conn:
            user_row = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        if user_row and check_password_hash(user_row['password_hash'], password):
            user = User(id=user_row['id'], username=user_row['username'], password_hash=user_row['password_hash'])
            login_user(user, remember=True)
            return redirect(request.args.get("next") or url_for('index'))
        flash('Invalid username or password', 'warning')
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))

@app.route('/setup', methods=['GET', 'POST'])
@login_required
def setup():
    settings = get_plex_settings()
    defaults = {'plex_protocol': 'http', 'plex_url': '', 'plex_port': '32400', 'plex_token': '', 'tmdb_api_key': ''}
    if settings: defaults.update(settings)
    if request.method == 'POST':
        is_new_plex_config = request.form.get('token') and (request.form.get('token') != defaults.get('plex_token'))
        with get_db() as conn:
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_protocol', request.form.get('protocol')))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_url', request.form.get('url')))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_port', request.form.get('port')))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_token', request.form.get('token')))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('tmdb_api_key', request.form.get('tmdb_api_key', '').strip()))
            new_username = request.form.get('new_username', '').strip()
            new_password = request.form.get('new_password')
            if new_username:
                conn.execute('UPDATE users SET username = ? WHERE id = ?', (new_username, current_user.id))
                flash('Username updated successfully.', 'info')
            if new_password:
                new_password_hash = generate_password_hash(new_password)
                conn.execute('UPDATE users SET password_hash = ? WHERE id = ?', (new_password_hash, current_user.id))
                flash('Password updated successfully.', 'info')
            conn.commit()
        if is_new_plex_config:
            global plex
            plex = None
            log('New Plex settings saved. Triggering initial library sync in the background.')
            flash('Plex settings saved! Your library is now being synced in the background. This may take several minutes.', 'info')
            python_exec = 'python'
            sync_script = os.path.join(PROJECT_DIR, 'sync_plex_library.py')
            subprocess.Popen([python_exec, sync_script])
            return redirect(url_for('index'))
        flash('Settings updated.', 'info')
        return redirect(url_for('setup'))
    return render_template('setup.html', errors=None, defaults=defaults)

@app.route('/plex_auth_start', methods=['POST'])
@login_required
def plex_auth_start():
    try:
        log("DEBUG: plex_auth_start - Manual Flow")
        client_id = 'PlexBarcodeRemote'
        headers = {
            'X-Plex-Client-Identifier': client_id,
            'X-Plex-Product': 'Plex Barcode Remote',
            'X-Plex-Device': 'Raspberry Pi',
            'Accept': 'application/json'
        }
        
        # 1. Get a PIN from Plex
        # We use the official Plex API v2 for pins
        response = requests.post('https://plex.tv/api/v2/pins?strong=true', headers=headers)
        if not response.ok:
            raise Exception(f"Plex PIN request failed: {response.status_code} {response.text}")
            
        data = response.json()
        pin_id = data.get('id')
        pin_code = data.get('code')
        
        log(f"DEBUG: Plex PIN response: {data}")
        
        session['plex_pin_id'] = pin_id
        session['plex_pin_code'] = pin_code
        
        # 2. Construct Auth URL
        from urllib.parse import urlencode
        params = {
            'pinID': pin_id,
            'code': pin_code,
            'clientID': client_id,
            'context[device][product]': 'Plex Barcode Remote',
            'context[device][version]': '1.0',
            'context[device][platform]': 'Raspberry Pi',
            'context[device][device]': 'Raspberry Pi'
        }
        auth_url = f"https://app.plex.tv/auth/#!?{urlencode(params)}"
        log(f"DEBUG: Constructed auth_url: {auth_url}")
        return jsonify({'auth_url': auth_url})
    except Exception as e:
        import traceback
        log(f"Plex Auth Start Error: {e}\n{traceback.format_exc()}")
        return jsonify({'error': str(e)}), 500

@app.route('/plex_auth_check', methods=['POST'])
@login_required
def plex_auth_check():
    pin_id = session.get('plex_pin_id')
    if not pin_id:
        return jsonify({'status': 'missing_session'}), 400
    
    try:
        log(f"DEBUG: plex_auth_check - ID={pin_id}")
        client_id = 'PlexBarcodeRemote'
        headers = {
            'X-Plex-Client-Identifier': client_id,
            'Accept': 'application/json'
        }
        
        # 3. Check PIN status via Plex API
        response = requests.get(f'https://plex.tv/api/v2/pins/{pin_id}', headers=headers)
        if not response.ok:
            log(f"DEBUG: PIN check failed: {response.status_code}")
            return jsonify({'status': 'waiting'})
            
        data = response.json()
        token = data.get('authToken')
        
        if token: 
            log("DEBUG: PIN Authenticated!")
            session['plex_token'] = token
            # Fetch servers using account token
            session_insecure = requests.Session()
            session_insecure.verify = False
            account = MyPlexAccount(token=token, session=session_insecure)
            resources = account.resources()
            servers = []
            for resource in resources:
                if 'server' in resource.provides:
                    for conn in resource.connections:
                        servers.append({
                            'name': f"{resource.name} ({conn.address})",
                            'uri': conn.uri,
                            'product': resource.product
                        })
            return jsonify({'status': 'authenticated', 'servers': servers})
        else:
            return jsonify({'status': 'waiting'})
    except Exception as e:
        import traceback
        log(f"Plex Auth Check Error: {e}\n{traceback.format_exc()}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

@app.route('/plex_server_save', methods=['POST'])
@login_required
def plex_server_save():
    server_uri = request.json.get('uri')
    server_name = request.json.get('name')
    token = session.get('plex_token')
    
    if not server_uri or not token:
        return jsonify({'error': 'Missing server URI or token'}), 400
    
    try:
        # Parse URI to components (simple version)
        # e.g. http://192.168.1.100:32400
        from urllib.parse import urlparse
        parsed = urlparse(server_uri)
        protocol = parsed.scheme
        hostname = parsed.hostname
        port = parsed.port or (80 if protocol == 'http' else 443)
        
        with get_db() as conn:
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_protocol', protocol))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_url', hostname))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_port', str(port)))
            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_token', token))
            conn.commit()
        
        # Reset global plex cache
        global plex
        plex = None
        
        log(f'Plex server configured via OAuth: {server_name} ({server_uri})')
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/force_sync', methods=['POST'])
@login_required
def force_sync():
    global plex
    plex = None
    log('Manual Force Refresh Metadata triggered. Reconnecting to Plex and starting library sync in the background.')
    flash('Manual refresh started! Your library is now being synced in the background. This may take several minutes.', 'info')
    python_exec = 'python'
    sync_script = os.path.join(PROJECT_DIR, 'sync_plex_library.py')
    subprocess.Popen([python_exec, sync_script])
    return redirect(url_for('index'))

@app.route('/')
@login_required
def index():
    if not get_plex_settings().get('plex_token'): return redirect(url_for('setup'))
    page = int(request.args.get('page', 1))
    per_page = int(request.args.get('per_page', 100))
    search_term = request.args.get('search', '').strip()
    genre_filter = request.args.get('genre', '').strip()
    with get_db() as conn:
        base_query = 'SELECT mi.*, b.barcode FROM media_items mi LEFT JOIN barcodes b ON mi.rating_key = b.rating_key'
        params = []
        conditions = []
        if search_term:
            conditions.append('mi.title LIKE ?')
            params.append(f'%{search_term}%')
        if genre_filter:
            conditions.append('mi.genres_json LIKE ?')
            params.append(f'%"{genre_filter}"%')
        
        # Total count query for pagination
        count_query = 'SELECT COUNT(*) FROM media_items mi'
        if conditions:
            count_query += ' WHERE ' + ' AND '.join(conditions)
        total_items = conn.execute(count_query, params).fetchone()[0]
        
        # Paginated query
        if conditions:
            base_query += ' WHERE ' + ' AND '.join(conditions)
        base_query += ' ORDER BY mi.title COLLATE NOCASE ASC'
        base_query += ' LIMIT ? OFFSET ?'
        paged_params = params + [per_page, (page - 1) * per_page]
        
        all_media_items_rows = conn.execute(base_query, paged_params).fetchall()
        all_genres_rows = conn.execute('SELECT DISTINCT genres_json FROM media_items').fetchall()
        all_ratings_rows = conn.execute("SELECT DISTINCT contentRating FROM media_items WHERE contentRating IS NOT NULL AND contentRating != '' ORDER BY contentRating").fetchall()
        known_clients = [row['name'] for row in conn.execute('SELECT name FROM known_clients').fetchall()]
        settings_rows = conn.execute('SELECT key, value FROM settings').fetchall()
    
    all_ratings = [row['contentRating'] for row in all_ratings_rows]
    all_genres = set()
    for row in all_genres_rows:
        if row['genres_json']:
            try:
                genres = json.loads(row['genres_json'])
                for genre in genres:
                    all_genres.add(genre)
            except (json.JSONDecodeError, TypeError):
                pass
    
    paginated_items = [dict(row) for row in all_media_items_rows]
    for item in paginated_items:
        try:
            item['directors'] = json.loads(item['directors_json'] or '[]')
            item['actors'] = json.loads(item['actors_json'] or '[]')
        except (json.JSONDecodeError, TypeError):
            item['directors'] = []
            item['actors'] = []
            
    total_pages = (total_items + per_page - 1) // per_page if per_page > 0 else 1
    settings = {row['key']: row['value'] for row in settings_rows}
    last_client = settings.get('last_client')
    scanner_mode = settings.get('scanner_mode', 'serial')
    scanner_device = settings.get('scanner_device', '/dev/ttyACM0')
    serial_ports = [port.device for port in list_ports.comports()]
    hid_devices = get_hid_devices()
    return render_template('index.html',
        items=paginated_items, last_client=last_client, scanner_mode=scanner_mode,
        scanner_device=scanner_device, serial_ports=serial_ports, hid_devices=hid_devices,
        page=page, per_page=per_page, total_items=total_items,
        total_pages=total_pages, search_term=search_term, genre_filter=genre_filter,
        genres=sorted(all_genres), clients=known_clients, ratings=all_ratings)

@app.route('/edit_barcode/<rating_key>', methods=['POST'])
@login_required
def edit_barcode(rating_key):
    new_barcode = request.form.get('barcode')
    if not new_barcode or not new_barcode.isdigit() or len(new_barcode) < 12:
        return jsonify({'error': 'Invalid barcode format. Must be 12+ digits.'}), 400
    try:
        with get_db() as conn:
            conn.execute('UPDATE barcodes SET barcode = ? WHERE rating_key = ?', (new_barcode, rating_key))
            conn.commit()
        log(f'Updated barcode for rating key {rating_key} to {new_barcode}')
        return jsonify({'message': 'Barcode updated successfully!'})
    except sqlite3.IntegrityError:
        return jsonify({'error': 'That barcode is already in use by another item.'}), 400
    except Exception as e:
        log(f'Error updating barcode: {e}')
        return jsonify({'error': 'An internal error occurred.'}), 500

@app.route('/actor/<path:actor_name>')
@login_required
def view_by_actor(actor_name):
    with get_db() as conn:
        query = 'SELECT * FROM media_items WHERE actors_json LIKE ? ORDER BY title'
        params = (f'%"{actor_name}"%',)
        results = [dict(row) for row in conn.execute(query, params).fetchall()]
    return render_template('results.html', query=actor_name, results=results, query_type='Actor')

@app.route('/director/<path:director_name>')
@login_required
def view_by_director(director_name):
    with get_db() as conn:
        query = 'SELECT * FROM media_items WHERE directors_json LIKE ? ORDER BY title'
        params = (f'%"{director_name}"%',)
        results = [dict(row) for row in conn.execute(query, params).fetchall()]
    return render_template('results.html', query=director_name, results=results, query_type='Director')

@app.route('/logs')
@login_required
def logs():
    days_str = request.args.get('days', '1')
    query = 'SELECT timestamp, source, message FROM logs'
    params = []
    if days_str.isdigit():
        query += " WHERE timestamp >= date('now', '-' || ? || ' days')"
        params.append(days_str)
    query += ' ORDER BY timestamp DESC'
    try:
        with get_db() as conn:
            log_entries = conn.execute(query, params).fetchall()
    except Exception as e:
        log(f'Error fetching logs from database: {e}')
        log_entries = []
    return render_template('logs.html', logs=log_entries, current_days=days_str)

@app.route('/poster/<rating_key>')
@login_required
def poster(rating_key):
    global plex
    if not plex: plex = get_plex_server()
    if not plex: return send_file(create_fallback_image('Plex connection failed'), mimetype='image/jpeg')
    try:
        item = plex.fetchItem(int(rating_key))
        poster_url = plex.url(item.thumb, includeToken=True) if item.thumb else None
        if not poster_url: return send_file(create_fallback_image('No poster'), mimetype='image/jpeg')
        response = requests.get(poster_url, timeout=5)
        response.raise_for_status()
        poster_img = Image.open(io.BytesIO(response.content))
        barcode_value = get_or_create_barcode(str(item.ratingKey), item.type)
        ean = barcode.get('ean13', barcode_value, writer=ImageWriter())
        barcode_buffer = io.BytesIO()
        ean.write(barcode_buffer)
        barcode_buffer.seek(0)
        barcode_img = Image.open(barcode_buffer)
        barcode_height = int(poster_img.height * 0.2)
        final_img = Image.new('RGB', (poster_img.width, poster_img.height + barcode_height), (255, 255, 255))
        final_img.paste(barcode_img.resize((poster_img.width, barcode_height)), (0, 0))
        final_img.paste(poster_img, (0, barcode_height))
        buf = io.BytesIO()
        final_img.save(buf, format='JPEG')
        buf.seek(0)
        return send_file(buf, mimetype='image/jpeg')
    except Exception as e:
        log(f"Error generating poster for {rating_key}: {e}")
        return send_file(create_fallback_image(str(e)), mimetype='image/jpeg')

@app.route('/play/<rating_key>', methods=['POST'])
@login_required
def play_media(rating_key):
    global plex
    if not plex: plex = get_plex_server()
    if not plex: return 'No Plex server connection', 500
    with get_db() as conn:
        client_row = conn.execute('SELECT value FROM settings WHERE key = "last_client"').fetchone()
        target_device_name = client_row['value'] if client_row else None
    if not target_device_name: return 'No device selected', 400
    try:
        media = plex.fetchItem(int(rating_key))
        log(f'Playing "{media.title}" on {target_device_name}')
    except Exception as e:
        log(f'Error fetching media for {rating_key}: {e}')
        return 'Error fetching media', 500
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
                client = plex.client(target_device_name)
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
                            for c in plex.clients():
                                if c.machineIdentifier == target_uuid: plex_client = c; break
                            if plex_client: break
                        except Exception: pass
                if not plex_client:
                    for c in plex.clients():
                        if c.machineIdentifier == target_uuid: plex_client = c; break
                if plex_client:
                    client_name = getattr(plex_client, "name", plex_client.title)
                    log(f'UUID match found! Client name is "{client_name}".')
                    plex_client.playMedia(media)
                else:
                    raise ConnectionError('Could not find a matching Chromecast client on Plex Server after wake-up.')
            return 'OK'
        except requests.exceptions.ConnectionError as e:
            log(f'Playback failed on attempt {attempt + 1}: Connection refused or failed.')
            if attempt < max_retries - 1:
                log(f'Retrying in {retry_delay} seconds...')
                time.sleep(retry_delay)
            else:
                log('All playback attempts failed.')
                return f'Failed to connect to client \'{target_device_name}\' after {max_retries} attempts. It may be offline.', 500
        except Exception as e:
            log(f'An unexpected error occurred during playback: {e}')
            return f'An unexpected error occurred: {e}', 500
    return 'All playback attempts failed.', 500

@app.route('/start_pdf_generation')
@login_required
def start_pdf_generation():
    pid_file = os.path.join(PROJECT_DIR, 'static', 'pdf_task.pid')
    status_file = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')
    files_json = os.path.join(PROJECT_DIR, 'static', 'pdf_files.json')
    if os.path.exists(pid_file):
        try:
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
            log(f'A previous PDF task (PID: {pid}) is running. Stopping it now.')
            os.kill(pid, signal.SIGTERM)
            flash('Stopping the previous PDF generation task.', 'warning')
        except (ProcessLookupError, ValueError) as e:
            log(f'Found a stale PID file but the process was not running: {e}')
        except Exception as e:
            log(f'Error while trying to stop previous PDF task: {e}')
    log('Waiting 2 seconds before starting new task...')
    time.sleep(2)
    log('Cleaning up old files before new generation.')
    if os.path.exists(status_file): os.remove(status_file)
    if os.path.exists(files_json): os.remove(files_json)
    if os.path.exists(pid_file): os.remove(pid_file)
    selected_rating = request.args.get('rating', 'all')
    log(f'Starting new background PDF generation task for rating: {selected_rating}.')
    python_exec = 'python'
    task_script = os.path.join(PROJECT_DIR, 'generate_pdf_task.py')
    process = subprocess.Popen([python_exec, task_script, selected_rating])
    with open(pid_file, 'w') as f:
        f.write(str(process.pid))
    flash('New PDF generation process started.', 'info')
    time.sleep(1)
    return redirect(url_for('index'))

@app.route('/stop_pdf_generation')
@login_required
def stop_pdf_generation():
    pid_file = os.path.join(PROJECT_DIR, 'static', 'pdf_task.pid')
    status_file = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')
    try:
        if os.path.exists(pid_file):
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
            log(f'Attempting to stop PDF generation process with PID: {pid}')
            os.kill(pid, signal.SIGTERM)
            flash('PDF generation process has been stopped.', 'info')
    except (ProcessLookupError, ValueError) as e:
        log(f'Could not stop process (it may have already finished): {e}')
        flash('PDF process was not found. It may have already finished.', 'warning')
    except Exception as e:
        log(f'Error stopping PDF process: {e}')
        flash(f'An error occurred while stopping the process: {e}', 'warning')
    finally:
        if os.path.exists(pid_file): os.remove(pid_file)
        with open(status_file, 'w') as f: f.write('error: Process stopped by user.')
    return redirect(url_for('index'))

@app.route('/pdf_status')
@login_required
def pdf_status():
    status_file = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')
    status = 'not_started'
    if os.path.exists(status_file):
        with open(status_file, 'r') as f: status = f.read().strip()
    return jsonify({'status': status})

@app.route('/get_pdf_files')
@login_required
def get_pdf_files():
    files_json_path = os.path.join(PROJECT_DIR, 'static', 'pdf_files.json')
    if os.path.exists(files_json_path):
        with open(files_json_path, 'r') as f:
            files = json.load(f)
        return jsonify(files)
    return jsonify([])

@app.route('/publish_status', methods=['POST'])
def publish_status():
    message = request.json.get('message')
    if message: sse.publish({'message': message}, type='greeting')
    return jsonify(success=True)

@app.route('/refresh_clients', methods=['POST'])
@login_required
def refresh_clients():
    global plex
    if not plex: plex = get_plex_server()
    if not plex: return jsonify({'error': 'No Plex server connection'}), 500
    try:
        active_clients = [getattr(c, 'name', c.title) for c in plex.clients()]
        cast_devices, _ = pychromecast.get_chromecasts()
        cast_names = [cc.name for cc in cast_devices]
        client_names = sorted(list(set(active_clients + cast_names)))
        with get_db() as conn:
            conn.execute('DELETE FROM known_clients')
            conn.executemany('INSERT OR IGNORE INTO known_clients (name) VALUES (?)', [(name,) for name in client_names])
            conn.commit()
        log(f'Refreshed clients: Found {len(client_names)} total devices')
        return jsonify({'clients': client_names})
    except Exception as e:
        log(f'Error refreshing clients: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/refresh_serial_ports', methods=['POST'])
@login_required
def refresh_serial_ports():
    try:
        ports = [port.device for port in list_ports.comports()]
        return jsonify({'ports': ports})
    except Exception as e:
        log(f'Error refreshing serial ports: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/refresh_hid_devices', methods=['POST'])
@login_required
def refresh_hid_devices():
    try:
        devices = get_hid_devices()
        return jsonify({'devices': devices})
    except Exception as e:
        log(f'Error refreshing HID devices: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/select_client', methods=['POST'])
@login_required
def select_client():
    client = request.form.get('client')
    if not client: return 'No client provided', 400
    with get_db() as conn:
        conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES ("last_client", ?)', (client,))
        conn.execute('INSERT OR IGNORE INTO known_clients (name) VALUES (?)', (client,))
        conn.commit()
    return redirect(url_for('index'))

@app.route('/save_scanner_settings', methods=['POST'])
@login_required
def save_scanner_settings():
    mode = request.form.get('scanner_mode')
    device = request.form.get('serial_device') if mode == 'serial' else request.form.get('hid_device')
    if not mode or not device: return 'Missing mode or device', 400
    with get_db() as conn:
        conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES ("scanner_mode", ?)', (mode,))
        conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES ("scanner_device", ?)', (device,))
        conn.commit()
    log(f'Settings saved. Please restart the plex-barcode-listener container to apply changes.')
    flash('Settings saved. Please restart the listener container manually.', 'info')
    return redirect(url_for('index'))

if __name__ == '__main__':
    with app.app_context():
        init_db()
        create_default_user()
    port = int(os.environ.get('FLASK_PORT', 5000))
    app.run(host='0.0.0.0', port=port, debug=False)




