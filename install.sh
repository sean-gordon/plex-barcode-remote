#!/bin/bash
set -e

echo "=== Plex Barcode Remote (Final, Complete Version) installer starting ==="

# ----------------------------------------------------------------------
# -------- CONFIG -------------------------------------------------------
# ----------------------------------------------------------------------
PROJECT_DIR="$HOME/plex_barcode_remote"
PERSISTENT_DIR="$HOME/.config/plex_barcode_remote"
DB_PATH="$PERSISTENT_DIR/barcodes.db"
FLASK_PORT=5000

# ----------------------------------------------------------------------
# -------- Install System Dependencies ------------------------------------
# ----------------------------------------------------------------------
echo "Installing system dependencies for Raspberry Pi OS..."
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip sqlite3 net-tools lsof python3-dev libevdev-dev curl redis-server

# ----------------------------------------------------------------------
# -------- 1. Setup Project ----------------------------------------------
# ----------------------------------------------------------------------
echo "[1/9] Setting up project directories..."
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static/generated_pdfs"
mkdir -p "$PERSISTENT_DIR/poster_cache"
cd "$PROJECT_DIR"

# ----------------------------------------------------------------------
# -------- 2. Setup Python -----------------------------------------------
# ----------------------------------------------------------------------
echo "[2/9] Setting up Python virtual environment and dependencies..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip uninstall -y fpdf fpdf2 keyboard || true
pip install flask requests plexapi pillow python-barcode pyserial evdev pychromecast fpdf2 Flask-SSE Flask-Login Werkzeug

# ----------------------------------------------------------------------
# -------- 3. Setup SQLite -----------------------------------------------
# ----------------------------------------------------------------------
echo "[3/9] Creating SQLite database..."
sqlite3 "$DB_PATH" "\
PRAGMA journal_mode=WAL;\
CREATE TABLE IF NOT EXISTS barcodes (\
    id INTEGER PRIMARY KEY AUTOINCREMENT,\
    rating_key TEXT UNIQUE NOT NULL,\
    barcode TEXT UNIQUE NOT NULL,\
    media_type TEXT NOT NULL\
);\
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY NOT NULL, value TEXT);\
CREATE TABLE IF NOT EXISTS known_clients (name TEXT PRIMARY KEY NOT NULL);\
CREATE TABLE IF NOT EXISTS logs (\
    id INTEGER PRIMARY KEY AUTOINCREMENT,\
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,\
    source TEXT NOT NULL,\
    message TEXT NOT NULL\
);\
CREATE TABLE IF NOT EXISTS users (\
    id INTEGER PRIMARY KEY AUTOINCREMENT,\
    username TEXT UNIQUE NOT NULL,\
    password_hash TEXT NOT NULL\
);\
CREATE TABLE IF NOT EXISTS media_items (rating_key TEXT PRIMARY KEY, title TEXT, year INTEGER, media_type TEXT, contentRating TEXT, thumb TEXT, directors_json TEXT, actors_json TEXT, genres_json TEXT);\
CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs (timestamp);\
INSERT OR IGNORE INTO settings (key, value) VALUES ('scanner_mode', 'serial');\
INSERT OR IGNORE INTO settings (key, value) VALUES ('scanner_device', '/dev/ttyACM0');"

# ----------------------------------------------------------------------
# -------- 4. Create Background Scripts --------------------------------
# ----------------------------------------------------------------------
echo "[4/9] Creating background scripts (this will be slow)..."
# --- sync_plex_library.py ---
echo "import os" > sync_plex_library.py
echo "import sqlite3" >> sync_plex_library.py
echo "import json" >> sync_plex_library.py
echo "import random" >> sync_plex_library.py
echo "from plexapi.server import PlexServer" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "def log(msg, conn, source='sync'):" >> sync_plex_library.py
echo "    print(f'[{source.upper()}] {msg}', flush=True)" >> sync_plex_library.py
echo "    try:" >> sync_plex_library.py
echo "        conn.execute(\"INSERT INTO logs (source, message) VALUES (?, ?)\", (source, msg))" >> sync_plex_library.py
echo "        conn.commit()" >> sync_plex_library.py
echo "    except Exception as e:" >> sync_plex_library.py
echo "        print(f\"Database logging failed: {e}\", flush=True)" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "def get_db():" >> sync_plex_library.py
echo "    conn = sqlite3.connect(DB_PATH, timeout=30)" >> sync_plex_library.py
echo "    conn.execute('PRAGMA journal_mode=WAL')" >> sync_plex_library.py
echo "    conn.row_factory = sqlite3.Row" >> sync_plex_library.py
echo "    return conn" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "def get_plex_server(conn):" >> sync_plex_library.py
echo "    settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN (\"plex_protocol\", \"plex_url\", \"plex_port\", \"plex_token\")')}" >> sync_plex_library.py
echo "    if not all(k in settings for k in ['plex_protocol', 'plex_url', 'plex_port', 'plex_token']): return None" >> sync_plex_library.py
echo "    try:" >> sync_plex_library.py
echo "        plex_url = f\"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}\"" >> sync_plex_library.py
echo "        return PlexServer(plex_url, settings['plex_token'])" >> sync_plex_library.py
echo "    except Exception as e:" >> sync_plex_library.py
echo "        log(f'Failed to connect to Plex server: {e}', conn=conn)" >> sync_plex_library.py
echo "        return None" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "def get_or_create_barcode_local(rating_key, media_type, conn):" >> sync_plex_library.py
echo "    row = conn.execute('SELECT barcode FROM barcodes WHERE rating_key = ?', (rating_key,)).fetchone()" >> sync_plex_library.py
echo "    if row: return" >> sync_plex_library.py
echo "    new_code = ''.join(str(random.randint(0, 9)) for _ in range(12))" >> sync_plex_library.py
echo "    try:" >> sync_plex_library.py
echo "        conn.execute('INSERT INTO barcodes (rating_key, barcode, media_type) VALUES (?, ?, ?)', (rating_key, new_code, media_type))" >> sync_plex_library.py
echo "    except sqlite3.IntegrityError:" >> sync_plex_library.py
echo "        log(f'Barcode collision for rating key {rating_key}, will retry on next sync.', conn=conn)" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "def main():" >> sync_plex_library.py
echo "    db_connection = get_db()" >> sync_plex_library.py
echo "    try:" >> sync_plex_library.py
echo "        log('Starting Plex library sync...', conn=db_connection)" >> sync_plex_library.py
echo "        plex = get_plex_server(conn=db_connection)" >> sync_plex_library.py
echo "        if not plex:" >> sync_plex_library.py
echo "            log('Sync failed: Could not connect to Plex server.', conn=db_connection)" >> sync_plex_library.py
echo "            return" >> sync_plex_library.py
echo "        all_media = plex.library.all()" >> sync_plex_library.py
echo "        log(f'Found {len(all_media)} items in Plex library.', conn=db_connection)" >> sync_plex_library.py
echo "        media_items_to_db = []" >> sync_plex_library.py
echo "        for item in all_media:" >> sync_plex_library.py
echo "            if item.type in ('movie', 'show'):" >> sync_plex_library.py
echo "                directors = json.dumps([d.tag for d in getattr(item, 'directors', [])])" >> sync_plex_library.py
echo "                actors = json.dumps([a.tag for a in getattr(item, 'actors', [])])" >> sync_plex_library.py
echo "                genres = json.dumps([g.tag for g in getattr(item, 'genres', [])])" >> sync_plex_library.py
echo "                media_items_to_db.append((" >> sync_plex_library.py
echo "                    str(item.ratingKey)," >> sync_plex_library.py
echo "                    item.title," >> sync_plex_library.py
echo "                    getattr(item, 'year', None)," >> sync_plex_library.py
echo "                    item.type," >> sync_plex_library.py
echo "                    getattr(item, 'contentRating', 'Unrated') or 'Unrated'," >> sync_plex_library.py
echo "                    item.thumb," >> sync_plex_library.py
echo "                    directors," >> sync_plex_library.py
echo "                    actors," >> sync_plex_library.py
echo "                    genres" >> sync_plex_library.py
echo "                ))" >> sync_plex_library.py
echo "        log('Clearing old media items table...', conn=db_connection)" >> sync_plex_library.py
echo "        db_connection.execute('DELETE FROM media_items')" >> sync_plex_library.py
echo "        log(f'Inserting {len(media_items_to_db)} new media items into database...', conn=db_connection)" >> sync_plex_library.py
echo "        db_connection.executemany('''" >> sync_plex_library.py
echo "            INSERT OR REPLACE INTO media_items (rating_key, title, year, media_type, contentRating, thumb, directors_json, actors_json, genres_json)" >> sync_plex_library.py
echo "            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)" >> sync_plex_library.py
echo "        ''', media_items_to_db)" >> sync_plex_library.py
echo "        db_connection.commit()" >> sync_plex_library.py
echo "        log('Verifying and creating barcodes for all media items...', conn=db_connection)" >> sync_plex_library.py
echo "        media_to_barcode = db_connection.execute('SELECT rating_key, media_type FROM media_items').fetchall()" >> sync_plex_library.py
echo "        count = 0" >> sync_plex_library.py
echo "        for item in media_to_barcode:" >> sync_plex_library.py
echo "            get_or_create_barcode_local(item['rating_key'], item['media_type'], db_connection)" >> sync_plex_library.py
echo "            count += 1" >> sync_plex_library.py
echo "        db_connection.commit()" >> sync_plex_library.py
echo "        log(f'Verified and created barcodes for {count} items.', conn=db_connection)" >> sync_plex_library.py
echo "        log('Plex library sync complete.', conn=db_connection)" >> sync_plex_library.py
echo "    except Exception as e:" >> sync_plex_library.py
echo "        log(f'An error occurred during sync: {e}', conn=conn)" >> sync_plex_library.py
echo "    finally:" >> sync_plex_library.py
echo "        db_connection.close()" >> sync_plex_library.py
echo "" >> sync_plex_library.py
echo "if __name__ == '__main__':" >> sync_plex_library.py
echo "    main()" >> sync_plex_library.py

# --- generate_pdf_task.py ---
echo "import os" > generate_pdf_task.py
echo "import sqlite3" >> generate_pdf_task.py
echo "import io" >> generate_pdf_task.py
echo "import random" >> generate_pdf_task.py
echo "import time" >> generate_pdf_task.py
echo "import shutil" >> generate_pdf_task.py
echo "import gc" >> generate_pdf_task.py
echo "import sys" >> generate_pdf_task.py
echo "import json" >> generate_pdf_task.py
echo "from plexapi.server import PlexServer" >> generate_pdf_task.py
echo "from PIL import Image, ImageDraw" >> generate_pdf_task.py
echo "import barcode" >> generate_pdf_task.py
echo "from barcode.writer import ImageWriter" >> generate_pdf_task.py
echo "import requests" >> generate_pdf_task.py
echo "from fpdf import FPDF" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')" >> generate_pdf_task.py
echo "CACHE_DIR = os.path.expanduser('~/.config/plex_barcode_remote/poster_cache')" >> generate_pdf_task.py
echo "OUTPUT_DIR = os.path.expanduser('~/plex_barcode_remote/static/generated_pdfs')" >> generate_pdf_task.py
echo "STATUS_FILE = os.path.expanduser('~/plex_barcode_remote/static/pdf_status.txt')" >> generate_pdf_task.py
echo "FILES_JSON = os.path.expanduser('~/plex_barcode_remote/static/pdf_files.json')" >> generate_pdf_task.py
echo "PID_FILE = os.path.expanduser('~/plex_barcode_remote/static/pdf_task.pid')" >> generate_pdf_task.py
echo "BATCH_SIZE = 25" >> generate_pdf_task.py
echo "POSTER_WIDTH = 300" >> generate_pdf_task.py
echo "POSTER_HEIGHT = 450" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "def log(msg, source='pdf_task'):" >> generate_pdf_task.py
echo "    print(f'[{source.upper()}] {msg}', flush=True)" >> generate_pdf_task.py
echo "    try:" >> generate_pdf_task.py
echo "        with get_db() as conn:" >> generate_pdf_task.py
echo "            conn.execute('INSERT INTO logs (source, message) VALUES (?, ?)', (source, msg))" >> generate_pdf_task.py
echo "            conn.commit()" >> generate_pdf_task.py
echo "    except Exception as e:" >> generate_pdf_task.py
echo "        print(f'Database logging failed: {e}', flush=True)" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "def get_db():" >> generate_pdf_task.py
echo "    conn = sqlite3.connect(DB_PATH, timeout=20)" >> generate_pdf_task.py
echo "    conn.execute('PRAGMA journal_mode=WAL')" >> generate_pdf_task.py
echo "    conn.row_factory = sqlite3.Row" >> generate_pdf_task.py
echo "    return conn" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "def get_plex_server():" >> generate_pdf_task.py
echo "    with get_db() as conn:" >> generate_pdf_task.py
echo "        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN (\"plex_protocol\", \"plex_url\", \"plex_port\", \"plex_token\")')}" >> generate_pdf_task.py
echo "    if not all(k in settings for k in ['plex_protocol', 'plex_url', 'plex_port', 'plex_token']):" >> generate_pdf_task.py
echo "        return None" >> generate_pdf_task.py
echo "    try:" >> generate_pdf_task.py
echo "        plex_url = f\"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}\"" >> generate_pdf_task.py
echo "        return PlexServer(plex_url, settings['plex_token'])" >> generate_pdf_task.py
echo "    except Exception as e:" >> generate_pdf_task.py
echo "        log(f'Failed to connect to Plex server: {e}')" >> generate_pdf_task.py
echo "        return None" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "def get_or_create_barcode(rating_key, media_type):" >> generate_pdf_task.py
echo "    with get_db() as conn:" >> generate_pdf_task.py
echo "        row = conn.execute('SELECT barcode FROM barcodes WHERE rating_key = ?', (rating_key,)).fetchone()" >> generate_pdf_task.py
echo "        if row: return row['barcode']" >> generate_pdf_task.py
echo "        new_code = ''.join(str(random.randint(0, 9)) for _ in range(12))" >> generate_pdf_task.py
echo "        try:" >> generate_pdf_task.py
echo "            conn.execute('INSERT INTO barcodes (rating_key, barcode, media_type) VALUES (?, ?, ?)', (rating_key, new_code, media_type))" >> generate_pdf_task.py
echo "            conn.commit()" >> generate_pdf_task.py
echo "        except sqlite3.IntegrityError:" >> generate_pdf_task.py
echo "            return get_or_create_barcode(rating_key, media_type)" >> generate_pdf_task.py
echo "        return new_code" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "def get_cached_poster(item_dict, plex):" >> generate_pdf_task.py
echo "    rating_key = item_dict['rating_key']" >> generate_pdf_task.py
echo "    thumb_url = item_dict['thumb']" >> generate_pdf_task.py
echo "    title = item_dict['title']" >> generate_pdf_task.py
echo "    cache_path = os.path.join(CACHE_DIR, f'{rating_key}.jpg')" >> generate_pdf_task.py
echo "    if os.path.exists(cache_path):" >> generate_pdf_task.py
echo "        with open(cache_path, 'rb') as f: return f.read()" >> generate_pdf_task.py
echo "    if thumb_url:" >> generate_pdf_task.py
echo "        try:" >> generate_pdf_task.py
echo "            poster_url = plex.url(f'{thumb_url}?width={POSTER_WIDTH}&height={POSTER_HEIGHT}&opacity=100', includeToken=True)" >> generate_pdf_task.py
echo "            response = requests.get(poster_url, timeout=10)" >> generate_pdf_task.py
echo "            response.raise_for_status()" >> generate_pdf_task.py
echo "            image_data = response.content" >> generate_pdf_task.py
echo "            with open(cache_path, 'wb') as f: f.write(image_data)" >> generate_pdf_task.py
echo "            return image_data" >> generate_pdf_task.py
echo "        except requests.exceptions.RequestException as e:" >> generate_pdf_task.py
echo "            log(f\"Cached thumb for '{title}' failed ({e}). Fetching live item for fresh URL.\")" >> generate_pdf_task.py
echo "    try:" >> generate_pdf_task.py
echo "        live_item = plex.fetchItem(int(rating_key))" >> generate_pdf_task.py
echo "        log(f\"Downloading poster for '{title}' with fresh URL.\")" >> generate_pdf_task.py
echo "        fresh_poster_url = plex.url(f'{live_item.thumb}?width={POSTER_WIDTH}&height={POSTER_HEIGHT}&opacity=100', includeToken=True)" >> generate_pdf_task.py
echo "        response = requests.get(fresh_poster_url, timeout=15)" >> generate_pdf_task.py
echo "        response.raise_for_status()" >> generate_pdf_task.py
echo "        image_data = response.content" >> generate_pdf_task.py
echo "        with open(cache_path, 'wb') as f: f.write(image_data)" >> generate_pdf_task.py
echo "        return image_data" >> generate_pdf_task.py
echo "    except Exception as e:" >> generate_pdf_task.py
echo "        log(f\"Final attempt to download poster for '{title}' failed: {e}\")" >> generate_pdf_task.py
echo "        raise" >> generate_pdf_task.py
echo "" >> generate_pdf_task.py
echo "def main():" >> generate_pdf_task.py
echo "    if len(sys.argv) > 1 and sys.argv[1] != 'all':" >> generate_pdf_task.py
echo "        selected_rating = sys.argv[1]" >> generate_pdf_task.py
echo "        log(f\"PDF generation started for rating: '{selected_rating}'\")" >> generate_pdf_task.py
echo "    else:" >> generate_pdf_task.py
echo "        selected_rating = None" >> generate_pdf_task.py
echo "        log(\"PDF generation started for all ratings.\")" >> generate_pdf_task.py
echo "    shutil.rmtree(OUTPUT_DIR, ignore_errors=True)" >> generate_pdf_task.py
echo "    os.makedirs(OUTPUT_DIR, exist_ok=True)" >> generate_pdf_task.py
echo "    try:" >> generate_pdf_task.py
echo "        with open(STATUS_FILE, 'w') as f: f.write('running')" >> generate_pdf_task.py
echo "        plex = get_plex_server()" >> generate_pdf_task.py
echo "        if not plex: raise ConnectionError('Could not connect to Plex server.')" >> generate_pdf_task.py
echo "        log('Fetching media from local cache...')" >> generate_pdf_task.py
echo "        with get_db() as conn:" >> generate_pdf_task.py
echo "            query = 'SELECT rating_key, title, contentRating, media_type, thumb FROM media_items'" >> generate_pdf_task.py
echo "            params = []" >> generate_pdf_task.py
echo "            if selected_rating:" >> generate_pdf_task.py
echo "                query += ' WHERE contentRating = ?'" >> generate_pdf_task.py
echo "                params.append(selected_rating)" >> generate_pdf_task.py
echo "            media_rows = conn.execute(query, params).fetchall()" >> generate_pdf_task.py
echo "        if not media_rows:" >> generate_pdf_task.py
echo "            if selected_rating:" >> generate_pdf_task.py
echo "                raise ValueError(f\"No media found with rating '{selected_rating}'. Run the sync script first.\")" >> generate_pdf_task.py
echo "            else:" >> generate_pdf_task.py
echo "                raise ValueError('No media found in local cache. Run the sync script first.')" >> generate_pdf_task.py
echo "        lean_media_list = [dict(row) for row in media_rows]" >> generate_pdf_task.py
echo "        grouped_media = {}" >> generate_pdf_task.py
echo "        for item in lean_media_list:" >> generate_pdf_task.py
echo "            rating = item['contentRating']" >> generate_pdf_task.py
echo "            if rating not in grouped_media: grouped_media[rating] = []" >> generate_pdf_task.py
echo "            grouped_media[rating].append(item)" >> generate_pdf_task.py
echo "        if not grouped_media: raise ValueError('No media found after grouping.')" >> generate_pdf_task.py
echo "        generated_files = []" >> generate_pdf_task.py
echo "        for rating, items in grouped_media.items():" >> generate_pdf_task.py
echo "            for i in range(0, len(items), BATCH_SIZE):" >> generate_pdf_task.py
echo "                batch = items[i:i + BATCH_SIZE]" >> generate_pdf_task.py
echo "                part_num = (i // BATCH_SIZE) + 1" >> generate_pdf_task.py
echo "                log(f'  - Generating PDF part {part_num} for rating: {rating}')" >> generate_pdf_task.py
echo "                pdf = FPDF(orientation='P', unit='mm', format='A4')" >> generate_pdf_task.py
echo "                pdf.set_auto_page_break(False)" >> generate_pdf_task.py
echo "                pdf.add_page()" >> generate_pdf_task.py
echo "                card_w, card_h = 63, 88" >> generate_pdf_task.py
echo "                margin = 5" >> generate_pdf_task.py
echo "                cols = int((pdf.w - (2 * margin)) / card_w)" >> generate_pdf_task.py
echo "                rows = int((pdf.h - (2 * margin)) / card_h)" >> generate_pdf_task.py
echo "                x_start = (pdf.w - (cols * card_w)) / 2" >> generate_pdf_task.py
echo "                y_start = (pdf.h - (rows * card_h)) / 2" >> generate_pdf_task.py
echo "                x, y = x_start, y_start" >> generate_pdf_task.py
echo "                item_count = 0" >> generate_pdf_task.py
echo "                for item_dict in batch:" >> generate_pdf_task.py
echo "                    if item_count > 0 and item_count % (cols * rows) == 0:" >> generate_pdf_task.py
echo "                        pdf.add_page()" >> generate_pdf_task.py
echo "                        x, y = x_start, y_start" >> generate_pdf_task.py
echo "                    try:" >> generate_pdf_task.py
echo "                        poster_data = get_cached_poster(item_dict, plex)" >> generate_pdf_task.py
echo "                        poster_img = Image.open(io.BytesIO(poster_data))" >> generate_pdf_task.py
echo "                        barcode_value = get_or_create_barcode(str(item_dict['rating_key']), item_dict['media_type'])" >> generate_pdf_task.py
echo "                        ean = barcode.get('ean13', barcode_value, writer=ImageWriter())" >> generate_pdf_task.py
echo "                        barcode_buffer = io.BytesIO()" >> generate_pdf_task.py
echo "                        ean.write(barcode_buffer)" >> generate_pdf_task.py
echo "                        barcode_buffer.seek(0)" >> generate_pdf_task.py
echo "                        barcode_img = Image.open(barcode_buffer)" >> generate_pdf_task.py
echo "                        barcode_height = int(poster_img.height * 0.2)" >> generate_pdf_task.py
echo "                        content_img = Image.new('RGB', (poster_img.width, poster_img.height + barcode_height), (255, 255, 255))" >> generate_pdf_task.py
echo "                        content_img.paste(barcode_img.resize((poster_img.width, barcode_height)), (0, 0))" >> generate_pdf_task.py
echo "                        content_img.paste(poster_img, (0, barcode_height))" >> generate_pdf_task.py
echo "                        border_px, radius_px = 20, 45" >> generate_pdf_task.py
echo "                        final_size = (content_img.width + 2 * border_px, content_img.height + 2 * border_px)" >> generate_pdf_task.py
echo "                        background = Image.new('RGB', final_size, 'black')" >> generate_pdf_task.py
echo "                        background.paste(content_img, (border_px, border_px))" >> generate_pdf_task.py
echo "                        mask = Image.new('L', final_size, 0)" >> generate_pdf_task.py
echo "                        draw = ImageDraw.Draw(mask)" >> generate_pdf_task.py
echo "                        draw.rounded_rectangle((0, 0) + final_size, radius=radius_px, fill=255)" >> generate_pdf_task.py
echo "                        background.putalpha(mask)" >> generate_pdf_task.py
echo "                        card_buffer = io.BytesIO()" >> generate_pdf_task.py
echo "                        background.save(card_buffer, format='PNG')" >> generate_pdf_task.py
echo "                        card_buffer.seek(0)" >> generate_pdf_task.py
echo "                        pdf.image(card_buffer, x=x, y=y, w=card_w, h=card_h, type='PNG')" >> generate_pdf_task.py
echo "                        del poster_data, poster_img, barcode_img, content_img, background, mask, draw, card_buffer" >> generate_pdf_task.py
echo "                    except Exception as e:" >> generate_pdf_task.py
echo "                        log(f\"Skipping '{item_dict['title']}' due to image error: {e}\")" >> generate_pdf_task.py
echo "                        pdf.set_fill_color(230, 230, 230)" >> generate_pdf_task.py
echo "                        pdf.rect(x, y, card_w, card_h, 'F')" >> generate_pdf_task.py
echo "                        pdf.set_xy(x, y + card_h/2)" >> generate_pdf_task.py
echo "                        pdf.set_font('helvetica', 'B', 8)" >> generate_pdf_task.py
echo "                        pdf.multi_cell(card_w, 4, f\"Error:\\n{item_dict['title']}\", align='C')" >> generate_pdf_task.py
echo "                    x += card_w" >> generate_pdf_task.py
echo "                    if (item_count + 1) % cols == 0:" >> generate_pdf_task.py
echo "                        x = x_start" >> generate_pdf_task.py
echo "                        y += card_h" >> generate_pdf_task.py
echo "                    item_count += 1" >> generate_pdf_task.py
echo "                    gc.collect()" >> generate_pdf_task.py
echo "                pdf_filename = f'Posters-{rating.replace(\"/\", \"_\")}-part{part_num}.pdf'" >> generate_pdf_task.py
echo "                pdf_path = os.path.join(OUTPUT_DIR, pdf_filename)" >> generate_pdf_task.py
echo "                pdf.output(pdf_path)" >> generate_pdf_task.py
echo "                generated_files.append(pdf_filename)" >> generate_pdf_task.py
echo "        log(f'Generated {len(generated_files)} PDF files.')" >> generate_pdf_task.py
echo "        with open(FILES_JSON, 'w') as f:" >> generate_pdf_task.py
echo "            json.dump(generated_files, f)" >> generate_pdf_task.py
echo "        with open(STATUS_FILE, 'w') as f: f.write('complete')" >> generate_pdf_task.py
echo "    except Exception as e:" >> generate_pdf_task.py
echo "        log(f'Error during PDF generation: {e}')" >> generate_pdf_task.py
echo "        with open(STATUS_FILE, 'w') as f: f.write(f'error: {e}')" >> generate_pdf_task.py
echo "if __name__ == '__main__':" >> generate_pdf_task.py
echo "    main()" >> generate_pdf_task.py

# ----------------------------------------------------------------------
# -------- 5. Main Flask Dashboard (web_dashboard.py) ------------------
# ----------------------------------------------------------------------
echo "[5/9] Creating Flask dashboard (web_dashboard.py)..."
echo "import os" > web_dashboard.py
echo "import sqlite3" >> web_dashboard.py
echo "import io" >> web_dashboard.py
echo "import random" >> web_dashboard.py
echo "import subprocess" >> web_dashboard.py
echo "import re" >> web_dashboard.py
echo "import time" >> web_dashboard.py
echo "import glob" >> web_dashboard.py
echo "import json" >> web_dashboard.py
echo "import signal" >> web_dashboard.py
echo "import evdev" >> web_dashboard.py
echo "from flask import Flask, render_template, request, redirect, url_for, send_file, jsonify, flash" >> web_dashboard.py
echo "from flask_sse import sse" >> web_dashboard.py
echo "from plexapi.server import PlexServer" >> web_dashboard.py
echo "from PIL import Image, ImageDraw, ImageFont" >> web_dashboard.py
echo "import barcode" >> web_dashboard.py
echo "from barcode.writer import ImageWriter" >> web_dashboard.py
echo "import requests" >> web_dashboard.py
echo "from serial.tools import list_ports" >> web_dashboard.py
echo "import pychromecast" >> web_dashboard.py
echo "from werkzeug.security import generate_password_hash, check_password_hash" >> web_dashboard.py
echo "from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')" >> web_dashboard.py
echo "PROJECT_DIR = os.path.expanduser('~/plex_barcode_remote')" >> web_dashboard.py
echo "app = Flask(__name__)" >> web_dashboard.py
echo "app.secret_key = os.urandom(24)" >> web_dashboard.py
echo "app.config['REDIS_URL'] = 'redis://localhost'" >> web_dashboard.py
echo "app.register_blueprint(sse, url_prefix='/stream')" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "login_manager = LoginManager()" >> web_dashboard.py
echo "login_manager.init_app(app)" >> web_dashboard.py
echo "login_manager.login_view = 'login'" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "class User(UserMixin):" >> web_dashboard.py
echo "    def __init__(self, id, username, password_hash):" >> web_dashboard.py
echo "        self.id = id" >> web_dashboard.py
echo "        self.username = username" >> web_dashboard.py
echo "        self.password_hash = password_hash" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@login_manager.user_loader" >> web_dashboard.py
echo "def load_user(user_id):" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        user_row = conn.execute('SELECT * FROM users WHERE id = ?', (user_id,)).fetchone()" >> web_dashboard.py
echo "        if user_row:" >> web_dashboard.py
echo "            return User(id=user_row['id'], username=user_row['username'], password_hash=user_row['password_hash'])" >> web_dashboard.py
echo "    return None" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def log(msg, source='web'):" >> web_dashboard.py
echo "    print(f'[{source.upper()}] {msg}', flush=True)" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        with get_db() as conn:" >> web_dashboard.py
echo "            conn.execute('INSERT INTO logs (source, message) VALUES (?, ?)', (source, msg))" >> web_dashboard.py
echo "            conn.commit()" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        print(f'Database logging failed: {e}', flush=True)" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def get_db():" >> web_dashboard.py
echo "    conn = sqlite3.connect(DB_PATH, timeout=20)" >> web_dashboard.py
echo "    conn.execute('PRAGMA journal_mode=WAL')" >> web_dashboard.py
echo "    conn.row_factory = sqlite3.Row" >> web_dashboard.py
echo "    return conn" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def create_default_user():" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        user = conn.execute('SELECT * FROM users').fetchone()" >> web_dashboard.py
echo "        if not user:" >> web_dashboard.py
echo "            log('No user found, creating default Admin user.')" >> web_dashboard.py
echo "            default_pass_hash = generate_password_hash('Admin')" >> web_dashboard.py
echo "            conn.execute('INSERT INTO users (username, password_hash) VALUES (?, ?)', ('Admin', default_pass_hash))" >> web_dashboard.py
echo "            conn.commit()" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def get_plex_settings():" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN (\"plex_protocol\", \"plex_url\", \"plex_port\", \"plex_token\", \"tmdb_api_key\")')}" >> web_dashboard.py
echo "        return settings" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def get_plex_server():" >> web_dashboard.py
echo "    settings = get_plex_settings()" >> web_dashboard.py
echo "    if not all(k in settings for k in ['plex_protocol', \"plex_url\", \"plex_port\", \"plex_token\"]):" >> web_dashboard.py
echo "        return None" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        plex_url = f\"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}\"" >> web_dashboard.py
echo "        return PlexServer(plex_url, settings['plex_token'])" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Failed to connect to Plex server: {e}')" >> web_dashboard.py
echo "        return None" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "plex = None" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def get_hid_devices():" >> web_dashboard.py
echo "    devices = []" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        for path in glob.glob('/dev/input/event*'):" >> web_dashboard.py
echo "            try:" >> web_dashboard.py
echo "                device = evdev.InputDevice(path)" >> web_dashboard.py
echo "                if evdev.ecodes.EV_KEY in device.capabilities():" >> web_dashboard.py
echo "                    devices.append({'path': path, 'name': device.name})" >> web_dashboard.py
echo "            except Exception:" >> web_dashboard.py
echo "                pass # Ignore devices we can't open" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error scanning for HID devices: {e}')" >> web_dashboard.py
echo "    return devices" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def get_or_create_barcode(rating_key, media_type):" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        row = conn.execute('SELECT barcode FROM barcodes WHERE rating_key = ?', (rating_key,)).fetchone()" >> web_dashboard.py
echo "        if row: return row['barcode']" >> web_dashboard.py
echo "        new_code = ''.join(str(random.randint(0, 9)) for _ in range(12))" >> web_dashboard.py
echo "        try:" >> web_dashboard.py
echo "            conn.execute('INSERT INTO barcodes (rating_key, barcode, media_type) VALUES (?, ?, ?)', (rating_key, new_code, media_type))" >> web_dashboard.py
echo "            conn.commit()" >> web_dashboard.py
echo "        except sqlite3.IntegrityError:" >> web_dashboard.py
echo "            return get_or_create_barcode(rating_key, media_type)" >> web_dashboard.py
echo "        return new_code" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "def create_fallback_image(error_message):" >> web_dashboard.py
echo "    img = Image.new('RGB', (300, 400), (255, 255, 255))" >> web_dashboard.py
echo "    draw = ImageDraw.Draw(img)" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        font = ImageFont.truetype(\"arial.ttf\", 20)" >> web_dashboard.py
echo "    except IOError:" >> web_dashboard.py
echo "        font = ImageFont.load_default()" >> web_dashboard.py
echo "    draw.text((10, 10), f'Error:\\n{error_message}', fill=(255,0,0), font=font)" >> web_dashboard.py
echo "    buf = io.BytesIO()" >> web_dashboard.py
echo "    img.save(buf, format='JPEG')" >> web_dashboard.py
echo "    buf.seek(0)" >> web_dashboard.py
echo "    return buf" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/login', methods=['GET', 'POST'])" >> web_dashboard.py
echo "def login():" >> web_dashboard.py
echo "    if current_user.is_authenticated:" >> web_dashboard.py
echo "        return redirect(url_for('index'))" >> web_dashboard.py
echo "    if request.method == 'POST':" >> web_dashboard.py
echo "        username = request.form.get('username')" >> web_dashboard.py
echo "        password = request.form.get('password')" >> web_dashboard.py
echo "        with get_db() as conn:" >> web_dashboard.py
echo "            user_row = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()" >> web_dashboard.py
echo "        if user_row and check_password_hash(user_row['password_hash'], password):" >> web_dashboard.py
echo "            user = User(id=user_row['id'], username=user_row['username'], password_hash=user_row['password_hash'])" >> web_dashboard.py
echo "            login_user(user, remember=True)" >> web_dashboard.py
echo "            return redirect(request.args.get(\"next\") or url_for('index'))" >> web_dashboard.py
echo "        flash('Invalid username or password', 'warning')" >> web_dashboard.py
echo "    return render_template('login.html')" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/logout')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def logout():" >> web_dashboard.py
echo "    logout_user()" >> web_dashboard.py
echo "    return redirect(url_for('login'))" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/setup', methods=['GET', 'POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def setup():" >> web_dashboard.py
echo "    settings = get_plex_settings()" >> web_dashboard.py
echo "    defaults = {'plex_protocol': 'http', 'plex_url': '', 'plex_port': '32400', 'plex_token': '', 'tmdb_api_key': ''}" >> web_dashboard.py
echo "    if settings: defaults.update(settings)" >> web_dashboard.py
echo "    if request.method == 'POST':" >> web_dashboard.py
echo "        is_new_plex_config = request.form.get('token') and (request.form.get('token') != defaults.get('plex_token'))" >> web_dashboard.py
echo "        with get_db() as conn:" >> web_dashboard.py
echo "            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_protocol', request.form.get('protocol')))" >> web_dashboard.py
echo "            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_url', request.form.get('url')))" >> web_dashboard.py
echo "            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_port', request.form.get('port')))" >> web_dashboard.py
echo "            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('plex_token', request.form.get('token')))" >> web_dashboard.py
echo "            conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', ('tmdb_api_key', request.form.get('tmdb_api_key', '').strip()))" >> web_dashboard.py
echo "            new_username = request.form.get('new_username', '').strip()" >> web_dashboard.py
echo "            new_password = request.form.get('new_password')" >> web_dashboard.py
echo "            if new_username:" >> web_dashboard.py
echo "                conn.execute('UPDATE users SET username = ? WHERE id = ?', (new_username, current_user.id))" >> web_dashboard.py
echo "                flash('Username updated successfully.', 'info')" >> web_dashboard.py
echo "            if new_password:" >> web_dashboard.py
echo "                new_password_hash = generate_password_hash(new_password)" >> web_dashboard.py
echo "                conn.execute('UPDATE users SET password_hash = ? WHERE id = ?', (new_password_hash, current_user.id))" >> web_dashboard.py
echo "                flash('Password updated successfully.', 'info')" >> web_dashboard.py
echo "            conn.commit()" >> web_dashboard.py
echo "        if is_new_plex_config:" >> web_dashboard.py
echo "            log('New Plex settings saved. Triggering initial library sync in the background.')" >> web_dashboard.py
echo "            flash('Plex settings saved! Your library is now being synced in the background. This may take several minutes.', 'info')" >> web_dashboard.py
echo "            python_exec = os.path.join(PROJECT_DIR, 'venv/bin/python')" >> web_dashboard.py
echo "            sync_script = os.path.join(PROJECT_DIR, 'sync_plex_library.py')" >> web_dashboard.py
echo "            subprocess.Popen([python_exec, sync_script])" >> web_dashboard.py
echo "            return redirect(url_for('index'))" >> web_dashboard.py
echo "        flash('Settings updated.', 'info')" >> web_dashboard.py
echo "        return redirect(url_for('setup'))" >> web_dashboard.py
echo "    return render_template('setup.html', errors=None, defaults=defaults)" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def index():" >> web_dashboard.py
echo "    if not get_plex_settings().get('plex_token'): return redirect(url_for('setup'))" >> web_dashboard.py
echo "    page = int(request.args.get('page', 1))" >> web_dashboard.py
echo "    per_page = int(request.args.get('per_page', 100))" >> web_dashboard.py
echo "    search_term = request.args.get('search', '').strip()" >> web_dashboard.py
echo "    genre_filter = request.args.get('genre', '').strip()" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        base_query = 'SELECT mi.*, b.barcode FROM media_items mi LEFT JOIN barcodes b ON mi.rating_key = b.rating_key'" >> web_dashboard.py
echo "        params = []" >> web_dashboard.py
echo "        conditions = []" >> web_dashboard.py
echo "        if search_term:" >> web_dashboard.py
echo "            conditions.append('mi.title LIKE ?')" >> web_dashboard.py
echo "            params.append(f'%{search_term}%')" >> web_dashboard.py
echo "        if genre_filter:" >> web_dashboard.py
echo "            conditions.append('mi.genres_json LIKE ?')" >> web_dashboard.py
echo "            params.append(f'%\"{genre_filter}\"%')" >> web_dashboard.py
echo "        if conditions:" >> web_dashboard.py
echo "            base_query += ' WHERE ' + ' AND '.join(conditions)" >> web_dashboard.py
echo "        all_media_items_rows = conn.execute(base_query, params).fetchall()" >> web_dashboard.py
echo "        all_genres_rows = conn.execute('SELECT DISTINCT genres_json FROM media_items').fetchall()" >> web_dashboard.py
echo "        all_ratings_rows = conn.execute(\"SELECT DISTINCT contentRating FROM media_items WHERE contentRating IS NOT NULL AND contentRating != '' ORDER BY contentRating\").fetchall()" >> web_dashboard.py
echo "        known_clients = [row['name'] for row in conn.execute('SELECT name FROM known_clients').fetchall()]" >> web_dashboard.py
echo "        settings_rows = conn.execute('SELECT key, value FROM settings').fetchall()" >> web_dashboard.py
echo "    all_ratings = [row['contentRating'] for row in all_ratings_rows]" >> web_dashboard.py
echo "    all_genres = set()" >> web_dashboard.py
echo "    for row in all_genres_rows:" >> web_dashboard.py
echo "        if row['genres_json']:" >> web_dashboard.py
echo "            try:" >> web_dashboard.py
echo "                genres = json.loads(row['genres_json'])" >> web_dashboard.py
echo "                for genre in genres:" >> web_dashboard.py
echo "                    all_genres.add(genre)" >> web_dashboard.py
echo "            except (json.JSONDecodeError, TypeError):" >> web_dashboard.py
echo "                pass" >> web_dashboard.py
echo "    processed_items = [dict(row) for row in all_media_items_rows]" >> web_dashboard.py
echo "    for item in processed_items:" >> web_dashboard.py
echo "        try:" >> web_dashboard.py
echo "            item['directors'] = json.loads(item['directors_json'] or '[]')" >> web_dashboard.py
echo "            item['actors'] = json.loads(item['actors_json'] or '[]')" >> web_dashboard.py
echo "        except (json.JSONDecodeError, TypeError):" >> web_dashboard.py
echo "            item['directors'] = []" >> web_dashboard.py
echo "            item['actors'] = []" >> web_dashboard.py
echo "    sorted_items = sorted(processed_items, key=lambda x: x['title'].lower())" >> web_dashboard.py
echo "    total_items = len(sorted_items)" >> web_dashboard.py
echo "    total_pages = (total_items + per_page - 1) // per_page if per_page > 0 else 1" >> web_dashboard.py
echo "    start = (page - 1) * per_page" >> web_dashboard.py
echo "    end = start + per_page" >> web_dashboard.py
echo "    paginated_items = sorted_items[start:end]" >> web_dashboard.py
echo "    settings = {row['key']: row['value'] for row in settings_rows}" >> web_dashboard.py
echo "    last_client = settings.get('last_client')" >> web_dashboard.py
echo "    scanner_mode = settings.get('scanner_mode', 'serial')" >> web_dashboard.py
echo "    scanner_device = settings.get('scanner_device', '/dev/ttyACM0')" >> web_dashboard.py
echo "    serial_ports = [port.device for port in list_ports.comports()]" >> web_dashboard.py
echo "    hid_devices = get_hid_devices()" >> web_dashboard.py
echo "    return render_template('index.html'," >> web_dashboard.py
echo "        items=paginated_items, last_client=last_client, scanner_mode=scanner_mode," >> web_dashboard.py
echo "        scanner_device=scanner_device, serial_ports=serial_ports, hid_devices=hid_devices," >> web_dashboard.py
echo "        page=page, per_page=per_page, total_items=total_items," >> web_dashboard.py
echo "        total_pages=total_pages, search_term=search_term, genre_filter=genre_filter," >> web_dashboard.py
echo "        genres=sorted(all_genres), clients=known_clients, ratings=all_ratings)" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/edit_barcode/<rating_key>', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def edit_barcode(rating_key):" >> web_dashboard.py
echo "    new_barcode = request.form.get('barcode')" >> web_dashboard.py
echo "    if not new_barcode or not new_barcode.isdigit() or len(new_barcode) < 12:" >> web_dashboard.py
echo "        return jsonify({'error': 'Invalid barcode format. Must be 12+ digits.'}), 400" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        with get_db() as conn:" >> web_dashboard.py
echo "            conn.execute('UPDATE barcodes SET barcode = ? WHERE rating_key = ?', (new_barcode, rating_key))" >> web_dashboard.py
echo "            conn.commit()" >> web_dashboard.py
echo "        log(f'Updated barcode for rating key {rating_key} to {new_barcode}')" >> web_dashboard.py
echo "        return jsonify({'message': 'Barcode updated successfully!'})" >> web_dashboard.py
echo "    except sqlite3.IntegrityError:" >> web_dashboard.py
echo "        return jsonify({'error': 'That barcode is already in use by another item.'}), 400" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error updating barcode: {e}')" >> web_dashboard.py
echo "        return jsonify({'error': 'An internal error occurred.'}), 500" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/actor/<path:actor_name>')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def view_by_actor(actor_name):" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        query = 'SELECT * FROM media_items WHERE actors_json LIKE ? ORDER BY title'" >> web_dashboard.py
echo "        params = (f'%\"{actor_name}\"%',)" >> web_dashboard.py
echo "        results = [dict(row) for row in conn.execute(query, params).fetchall()]" >> web_dashboard.py
echo "    return render_template('results.html', query=actor_name, results=results, query_type='Actor')" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/director/<path:director_name>')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def view_by_director(director_name):" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        query = 'SELECT * FROM media_items WHERE directors_json LIKE ? ORDER BY title'" >> web_dashboard.py
echo "        params = (f'%\"{director_name}\"%',)" >> web_dashboard.py
echo "        results = [dict(row) for row in conn.execute(query, params).fetchall()]" >> web_dashboard.py
echo "    return render_template('results.html', query=director_name, results=results, query_type='Director')" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/logs')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def logs():" >> web_dashboard.py
echo "    days_str = request.args.get('days', '1')" >> web_dashboard.py
echo "    query = 'SELECT timestamp, source, message FROM logs'" >> web_dashboard.py
echo "    params = []" >> web_dashboard.py
echo "    if days_str.isdigit():" >> web_dashboard.py
echo "        query += \" WHERE timestamp >= date('now', '-' || ? || ' days')\"" >> web_dashboard.py
echo "        params.append(days_str)" >> web_dashboard.py
echo "    query += ' ORDER BY timestamp DESC'" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        with get_db() as conn:" >> web_dashboard.py
echo "            log_entries = conn.execute(query, params).fetchall()" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error fetching logs from database: {e}')" >> web_dashboard.py
echo "        log_entries = []" >> web_dashboard.py
echo "    return render_template('logs.html', logs=log_entries, current_days=days_str)" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/poster/<rating_key>')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def poster(rating_key):" >> web_dashboard.py
echo "    global plex" >> web_dashboard.py
echo "    if not plex: plex = get_plex_server()" >> web_dashboard.py
echo "    if not plex: return send_file(create_fallback_image('Plex connection failed'), mimetype='image/jpeg')" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        item = plex.fetchItem(int(rating_key))" >> web_dashboard.py
echo "        poster_url = plex.url(item.thumb, includeToken=True) if item.thumb else None" >> web_dashboard.py
echo "        if not poster_url: return send_file(create_fallback_image('No poster'), mimetype='image/jpeg')" >> web_dashboard.py
echo "        response = requests.get(poster_url, timeout=5)" >> web_dashboard.py
echo "        response.raise_for_status()" >> web_dashboard.py
echo "        poster_img = Image.open(io.BytesIO(response.content))" >> web_dashboard.py
echo "        barcode_value = get_or_create_barcode(str(item.ratingKey), item.type)" >> web_dashboard.py
echo "        ean = barcode.get('ean13', barcode_value, writer=ImageWriter())" >> web_dashboard.py
echo "        barcode_buffer = io.BytesIO()" >> web_dashboard.py
echo "        ean.write(barcode_buffer)" >> web_dashboard.py
echo "        barcode_buffer.seek(0)" >> web_dashboard.py
echo "        barcode_img = Image.open(barcode_buffer)" >> web_dashboard.py
echo "        barcode_height = int(poster_img.height * 0.2)" >> web_dashboard.py
echo "        final_img = Image.new('RGB', (poster_img.width, poster_img.height + barcode_height), (255, 255, 255))" >> web_dashboard.py
echo "        final_img.paste(barcode_img.resize((poster_img.width, barcode_height)), (0, 0))" >> web_dashboard.py
echo "        final_img.paste(poster_img, (0, barcode_height))" >> web_dashboard.py
echo "        buf = io.BytesIO()" >> web_dashboard.py
echo "        final_img.save(buf, format='JPEG')" >> web_dashboard.py
echo "        buf.seek(0)" >> web_dashboard.py
echo "        return send_file(buf, mimetype='image/jpeg')" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f\"Error generating poster for {rating_key}: {e}\")" >> web_dashboard.py
echo "        return send_file(create_fallback_image(str(e)), mimetype='image/jpeg')" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/play/<rating_key>', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def play_media(rating_key):" >> web_dashboard.py
echo "    global plex" >> web_dashboard.py
echo "    if not plex: plex = get_plex_server()" >> web_dashboard.py
echo "    if not plex: return 'No Plex server connection', 500" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        client_row = conn.execute('SELECT value FROM settings WHERE key = \"last_client\"').fetchone()" >> web_dashboard.py
echo "        target_device_name = client_row['value'] if client_row else None" >> web_dashboard.py
echo "    if not target_device_name: return 'No device selected', 400" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        media = plex.fetchItem(int(rating_key))" >> web_dashboard.py
echo "        log(f'Playing \"{media.title}\" on {target_device_name}')" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error fetching media for {rating_key}: {e}')" >> web_dashboard.py
echo "        return 'Error fetching media', 500" >> web_dashboard.py
echo "    is_chromecast = False" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        casts, _ = pychromecast.get_listed_chromecasts(friendly_names=[target_device_name])" >> web_dashboard.py
echo "        if casts: is_chromecast = True" >> web_dashboard.py
echo "    except Exception: log('Chromecast discovery failed.')" >> web_dashboard.py
echo "    max_retries = 3" >> web_dashboard.py
echo "    retry_delay = 3" >> web_dashboard.py
echo "    for attempt in range(max_retries):" >> web_dashboard.py
echo "        try:" >> web_dashboard.py
echo "            if not is_chromecast:" >> web_dashboard.py
echo "                log(f'Attempting playback on {target_device_name} (attempt {attempt + 1}/{max_retries})...')" >> web_dashboard.py
echo "                client = plex.client(target_device_name)" >> web_dashboard.py
echo "                client.playMedia(media)" >> web_dashboard.py
echo "                log(f'Playback command sent for \"{media.title}\" to {target_device_name}.')" >> web_dashboard.py
echo "            else:" >> web_dashboard.py
echo "                log(f'Attempting Chromecast playback on {target_device_name} (attempt {attempt + 1}/{max_retries})...')" >> web_dashboard.py
echo "                plex_client = None" >> web_dashboard.py
echo "                casts[0].wait()" >> web_dashboard.py
echo "                target_uuid = str(casts[0].cast_info.uuid).replace('-', '')" >> web_dashboard.py
echo "                if casts[0].app_id != '9AC19493':" >> web_dashboard.py
echo "                    log('Plex app is not running. Launching app...')" >> web_dashboard.py
echo "                    casts[0].start_app('9AC19493')" >> web_dashboard.py
echo "                    for _ in range(10):" >> web_dashboard.py
echo "                        time.sleep(2)" >> web_dashboard.py
echo "                        try:" >> web_dashboard.py
echo "                            for c in plex.clients():" >> web_dashboard.py
echo "                                if c.machineIdentifier == target_uuid: plex_client = c; break" >> web_dashboard.py
echo "                            if plex_client: break" >> web_dashboard.py
echo "                        except Exception: pass" >> web_dashboard.py
echo "                if not plex_client:" >> web_dashboard.py
echo "                    for c in plex.clients():" >> web_dashboard.py
echo "                        if c.machineIdentifier == target_uuid: plex_client = c; break" >> web_dashboard.py
echo "                if plex_client:" >> web_dashboard.py
echo "                    client_name = getattr(plex_client, \"name\", plex_client.title)" >> web_dashboard.py
echo "                    log(f'UUID match found! Client name is \"{client_name}\".')" >> web_dashboard.py
echo "                    plex_client.playMedia(media)" >> web_dashboard.py
echo "                else:" >> web_dashboard.py
echo "                    raise ConnectionError('Could not find a matching Chromecast client on Plex Server after wake-up.')" >> web_dashboard.py
echo "            return 'OK'" >> web_dashboard.py
echo "        except requests.exceptions.ConnectionError as e:" >> web_dashboard.py
echo "            log(f'Playback failed on attempt {attempt + 1}: Connection refused or failed.')" >> web_dashboard.py
echo "            if attempt < max_retries - 1:" >> web_dashboard.py
echo "                log(f'Retrying in {retry_delay} seconds...')" >> web_dashboard.py
echo "                time.sleep(retry_delay)" >> web_dashboard.py
echo "            else:" >> web_dashboard.py
echo "                log('All playback attempts failed.')" >> web_dashboard.py
echo "                return f'Failed to connect to client \'{target_device_name}\' after {max_retries} attempts. It may be offline.', 500" >> web_dashboard.py
echo "        except Exception as e:" >> web_dashboard.py
echo "            log(f'An unexpected error occurred during playback: {e}')" >> web_dashboard.py
echo "            return f'An unexpected error occurred: {e}', 500" >> web_dashboard.py
echo "    return 'All playback attempts failed.', 500" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/start_pdf_generation')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def start_pdf_generation():" >> web_dashboard.py
echo "    pid_file = os.path.join(PROJECT_DIR, 'static', 'pdf_task.pid')" >> web_dashboard.py
echo "    status_file = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')" >> web_dashboard.py
echo "    files_json = os.path.join(PROJECT_DIR, 'static', 'pdf_files.json')" >> web_dashboard.py
echo "    if os.path.exists(pid_file):" >> web_dashboard.py
echo "        try:" >> web_dashboard.py
echo "            with open(pid_file, 'r') as f:" >> web_dashboard.py
echo "                pid = int(f.read().strip())" >> web_dashboard.py
echo "            log(f'A previous PDF task (PID: {pid}) is running. Stopping it now.')" >> web_dashboard.py
echo "            os.kill(pid, signal.SIGTERM)" >> web_dashboard.py
echo "            flash('Stopping the previous PDF generation task.', 'warning')" >> web_dashboard.py
echo "        except (ProcessLookupError, ValueError) as e:" >> web_dashboard.py
echo "            log(f'Found a stale PID file but the process was not running: {e}')" >> web_dashboard.py
echo "        except Exception as e:" >> web_dashboard.py
echo "            log(f'Error while trying to stop previous PDF task: {e}')" >> web_dashboard.py
echo "    log('Waiting 2 seconds before starting new task...')" >> web_dashboard.py
echo "    time.sleep(2)" >> web_dashboard.py
echo "    log('Cleaning up old files before new generation.')" >> web_dashboard.py
echo "    if os.path.exists(status_file): os.remove(status_file)" >> web_dashboard.py
echo "    if os.path.exists(files_json): os.remove(files_json)" >> web_dashboard.py
echo "    if os.path.exists(pid_file): os.remove(pid_file)" >> web_dashboard.py
echo "    selected_rating = request.args.get('rating', 'all')" >> web_dashboard.py
echo "    log(f'Starting new background PDF generation task for rating: {selected_rating}.')" >> web_dashboard.py
echo "    python_exec = os.path.join(PROJECT_DIR, 'venv/bin/python')" >> web_dashboard.py
echo "    task_script = os.path.join(PROJECT_DIR, 'generate_pdf_task.py')" >> web_dashboard.py
echo "    process = subprocess.Popen([python_exec, task_script, selected_rating])" >> web_dashboard.py
echo "    with open(pid_file, 'w') as f:" >> web_dashboard.py
echo "        f.write(str(process.pid))" >> web_dashboard.py
echo "    flash('New PDF generation process started.', 'info')" >> web_dashboard.py
echo "    time.sleep(1)" >> web_dashboard.py
echo "    return redirect(url_for('index'))" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/stop_pdf_generation')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def stop_pdf_generation():" >> web_dashboard.py
echo "    pid_file = os.path.join(PROJECT_DIR, 'static', 'pdf_task.pid')" >> web_dashboard.py
echo "    status_file = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        if os.path.exists(pid_file):" >> web_dashboard.py
echo "            with open(pid_file, 'r') as f:" >> web_dashboard.py
echo "                pid = int(f.read().strip())" >> web_dashboard.py
echo "            log(f'Attempting to stop PDF generation process with PID: {pid}')" >> web_dashboard.py
echo "            os.kill(pid, signal.SIGTERM)" >> web_dashboard.py
echo "            flash('PDF generation process has been stopped.', 'info')" >> web_dashboard.py
echo "    except (ProcessLookupError, ValueError) as e:" >> web_dashboard.py
echo "        log(f'Could not stop process (it may have already finished): {e}')" >> web_dashboard.py
echo "        flash('PDF process was not found. It may have already finished.', 'warning')" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error stopping PDF process: {e}')" >> web_dashboard.py
echo "        flash(f'An error occurred while stopping the process: {e}', 'warning')" >> web_dashboard.py
echo "    finally:" >> web_dashboard.py
echo "        if os.path.exists(pid_file): os.remove(pid_file)" >> web_dashboard.py
echo "        with open(status_file, 'w') as f: f.write('error: Process stopped by user.')" >> web_dashboard.py
echo "    return redirect(url_for('index'))" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/pdf_status')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def pdf_status():" >> web_dashboard.py
echo "    status_file = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')" >> web_dashboard.py
echo "    status = 'not_started'" >> web_dashboard.py
echo "    if os.path.exists(status_file):" >> web_dashboard.py
echo "        with open(status_file, 'r') as f: status = f.read().strip()" >> web_dashboard.py
echo "    return jsonify({'status': status})" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/get_pdf_files')" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def get_pdf_files():" >> web_dashboard.py
echo "    files_json_path = os.path.join(PROJECT_DIR, 'static', 'pdf_files.json')" >> web_dashboard.py
echo "    if os.path.exists(files_json_path):" >> web_dashboard.py
echo "        with open(files_json_path, 'r') as f:" >> web_dashboard.py
echo "            files = json.load(f)" >> web_dashboard.py
echo "        return jsonify(files)" >> web_dashboard.py
echo "    return jsonify([])" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/publish_status', methods=['POST'])" >> web_dashboard.py
echo "def publish_status():" >> web_dashboard.py
echo "    message = request.json.get('message')" >> web_dashboard.py
echo "    if message: sse.publish({'message': message}, type='greeting')" >> web_dashboard.py
echo "    return jsonify(success=True)" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/refresh_clients', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def refresh_clients():" >> web_dashboard.py
echo "    global plex" >> web_dashboard.py
echo "    if not plex: plex = get_plex_server()" >> web_dashboard.py
echo "    if not plex: return jsonify({'error': 'No Plex server connection'}), 500" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        active_clients = [getattr(c, 'name', c.title) for c in plex.clients()]" >> web_dashboard.py
echo "        cast_devices, _ = pychromecast.get_chromecasts()" >> web_dashboard.py
echo "        cast_names = [cc.name for cc in cast_devices]" >> web_dashboard.py
echo "        client_names = sorted(list(set(active_clients + cast_names)))" >> web_dashboard.py
echo "        with get_db() as conn:" >> web_dashboard.py
echo "            conn.execute('DELETE FROM known_clients')" >> web_dashboard.py
echo "            conn.executemany('INSERT OR IGNORE INTO known_clients (name) VALUES (?)', [(name,) for name in client_names])" >> web_dashboard.py
echo "            conn.commit()" >> web_dashboard.py
echo "        log(f'Refreshed clients: Found {len(client_names)} total devices')" >> web_dashboard.py
echo "        return jsonify({'clients': client_names})" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error refreshing clients: {e}')" >> web_dashboard.py
echo "        return jsonify({'error': str(e)}), 500" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/refresh_serial_ports', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def refresh_serial_ports():" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        ports = [port.device for port in list_ports.comports()]" >> web_dashboard.py
echo "        return jsonify({'ports': ports})" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error refreshing serial ports: {e}')" >> web_dashboard.py
echo "        return jsonify({'error': str(e)}), 500" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/refresh_hid_devices', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def refresh_hid_devices():" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        devices = get_hid_devices()" >> web_dashboard.py
echo "        return jsonify({'devices': devices})" >> web_dashboard.py
echo "    except Exception as e:" >> web_dashboard.py
echo "        log(f'Error refreshing HID devices: {e}')" >> web_dashboard.py
echo "        return jsonify({'error': str(e)}), 500" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/select_client', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def select_client():" >> web_dashboard.py
echo "    client = request.form.get('client')" >> web_dashboard.py
echo "    if not client: return 'No client provided', 400" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (\"last_client\", ?)', (client,))" >> web_dashboard.py
echo "        conn.execute('INSERT OR IGNORE INTO known_clients (name) VALUES (?)', (client,))" >> web_dashboard.py
echo "        conn.commit()" >> web_dashboard.py
echo "    return redirect(url_for('index'))" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "@app.route('/save_scanner_settings', methods=['POST'])" >> web_dashboard.py
echo "@login_required" >> web_dashboard.py
echo "def save_scanner_settings():" >> web_dashboard.py
echo "    mode = request.form.get('scanner_mode')" >> web_dashboard.py
echo "    device = request.form.get('serial_device') if mode == 'serial' else request.form.get('hid_device')" >> web_dashboard.py
echo "    if not mode or not device: return 'Missing mode or device', 400" >> web_dashboard.py
echo "    with get_db() as conn:" >> web_dashboard.py
echo "        conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (\"scanner_mode\", ?)', (mode,))" >> web_dashboard.py
echo "        conn.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (\"scanner_device\", ?)', (device,))" >> web_dashboard.py
echo "        conn.commit()" >> web_dashboard.py
echo "    try:" >> web_dashboard.py
echo "        subprocess.run(['sudo', 'systemctl', 'restart', 'plex-barcode-listener.service'], check=True)" >> web_dashboard.py
echo "        log(f'Restarted barcode listener with mode={mode} device={device}')" >> web_dashboard.py
echo "    except subprocess.CalledProcessError as e:" >> web_dashboard.py
echo "        log(f'Error restarting barcode listener: {e}')" >> web_dashboard.py
echo "        return 'Error restarting service', 500" >> web_dashboard.py
echo "    return redirect(url_for('index'))" >> web_dashboard.py
echo "" >> web_dashboard.py
echo "if __name__ == '__main__':" >> web_dashboard.py
echo "    with app.app_context():" >> web_dashboard.py
echo "        create_default_user()" >> web_dashboard.py
echo "    port = int(os.environ.get('FLASK_PORT', 5000))" >> web_dashboard.py
echo "    app.run(host='0.0.0.0', port=port, debug=False)" >> web_dashboard.py

# ----------------------------------------------------------------------
# -------- 6. HTML Templates -------------------------------------------
# ----------------------------------------------------------------------
echo "[6/9] Creating HTML templates..."
echo "<!DOCTYPE html><html><head><title>Login - Plex Barcode Remote</title><link rel=\"stylesheet\" href=\"{{ url_for('static', filename='style.css') }}\"></head><body><h1>Plex Barcode Remote Login <button id=\"theme-toggle\">☀️</button></h1><div class='form-container'>{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}<div class='flash-container'>{% for category, message in messages %}<div class=\"flash {{ category }}\">{{ message }}</div>{% endfor %}</div>{% endif %}{% endwith %}<form method='post'><div class='form-group'><label for='username'>Username</label><input type='text' id='username' name='username' required></div><div class='form-group'><label for='password'>Password</label><input type='password' id='password' name='password' required></div><button type='submit'>Login</button></form></div><script>document.getElementById('theme-toggle').addEventListener('click',()=>{let e=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',e?'dark':'light');updateThemeIcon(e)});function updateThemeIcon(e){document.getElementById('theme-toggle').textContent=e?'🌙':'☀️'}if(localStorage.getItem('theme')==='dark'||!localStorage.getItem('theme')&&window.matchMedia('(prefers-color-scheme: dark)').matches){document.body.classList.add('dark-mode');updateThemeIcon(true)}</script></body></html>" > templates/login.html

echo "<!DOCTYPE html><html><head><title>Plex Barcode Dashboard - Setup</title><link rel=\"stylesheet\" href=\"{{ url_for('static', filename='style.css') }}\"></head><body><h1>Plex Server Setup <button id=\"theme-toggle\">☀️</button></h1><div class='form-container'>{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class=\"flash {{ category }}\">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}{% if errors %}<div class='error'><ul>{% for error in errors %}<li>{{ error }}</li>{% endfor %}</ul></div>{% endif %}<form method='POST' action='/setup'><h3>Plex & TMDB Settings</h3><div class='form-group'><label>Protocol:</label><input type='radio' name='protocol' value='http' {% if defaults.plex_protocol == 'http' %}checked{% endif %}> HTTP <input type='radio' name='protocol' value='https' {% if defaults.plex_protocol == 'https' %}checked{% endif %}> HTTPS</div><div class='form-group'><label for='url'>URL or IP Address:</label><input type='text' id='url' name='url' value='{{ defaults.plex_url }}' placeholder='e.g., 192.168.1.100'></div><div class='form-group'><label for='port'>Port:</label><input type='number' id='port' name='port' value='{{ defaults.plex_port }}' placeholder='e.g., 32400' min='1' max='65535'></div><div class='form-group'><label for='token'>Plex Token:</label><input type='text' id='token' name='token' value='{{ defaults.plex_token }}' placeholder='Enter your Plex token'><p><a href='https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/' target='_blank'>How to find your Plex token</a></p></div><div class='form-group'><label for='tmdb_api_key'>TMDB API Key (Optional):</label><input type='text' id='tmdb_api_key' name='tmdb_api_key' value='{{ defaults.tmdb_api_key }}' placeholder='For missing barcode lookup'><p><a href='https://www.themoviedb.org/settings/api' target='_blank'>How to get a TMDB API key</a></p></div><hr><h3>User Management</h3><div class='form-group'><label for='new_username'>Change Username</label><input type='text' id='new_username' name='new_username' placeholder=\"Current: {{ current_user.username }}\"></div><div class='form-group'><label for='new_password'>Change Password</label><input type='password' id='new_password' name='new_password' placeholder='Leave blank to keep current password'></div><button type='submit'>Save Settings</button></form><p style='margin-top: 20px;'><a href=\"{{ url_for('index') }}\" class=\"button-link\">Back to Dashboard</a></p></div><script>document.getElementById('theme-toggle').addEventListener('click',()=>{let e=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',e?'dark':'light');updateThemeIcon(e)});function updateThemeIcon(e){document.getElementById('theme-toggle').textContent=e?'🌙':'☀️'}if(localStorage.getItem('theme')==='dark'||!localStorage.getItem('theme')&&window.matchMedia('(prefers-color-scheme: dark)').matches){document.body.classList.add('dark-mode');updateThemeIcon(true)}</script></body></html>" > templates/setup.html

echo "<!DOCTYPE html><html><head><title>Plex Barcode Dashboard</title><link rel=\"stylesheet\" href=\"{{ url_for('static', filename='style.css') }}\"></head><body><h1>Plex Barcode Dashboard <button id=\"theme-toggle\">☀️</button></h1>{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}<div class='flash-container'>{% for category, message in messages %}<div class=\"flash {{ category }}\">{{ message }}</div>{% endfor %}</div>{% endif %}{% endwith %}<div class='controls-grid'><div class='control-group'><h3>Live Status</h3><div id=\"status-box\">Ready...</div></div><div class='control-group'><h3>Playback Target</h3><form method='POST' action='/select_client'><label for='client'>Target Device:</label><select name='client' id='client_select'><option value=''>Select a Device</option></select><button type='submit'>Set</button><button type='button' onclick='refreshClients()'>Refresh Clients</button></form>{% if last_client %}<p style='color:green;'>Selected Target: <strong>{{ last_client }}</strong></p>{% endif %}</div><div class='control-group'><h3>Scanner Settings</h3><form method='POST' action='/save_scanner_settings' id='scanner-form'><div class='radio-group'><label><input type='radio' name='scanner_mode' value='serial' {% if scanner_mode == 'serial' %}checked{% endif %}> Serial</label><label><input type='radio' name='scanner_mode' value='hid' {% if scanner_mode == 'hid' %}checked{% endif %}> HID Keyboard</label></div><div id='serial-group'><label for='serial_device'>Serial Port:</label><select name='serial_device' id='serial_device_select'></select></div><div id='hid-group' style='display:none;'><label for='hid_device'>HID Device:</label><select name='hid_device' id='hid_device_select'></select></div><button type='submit'>Save & Restart Listener</button></form><div class='button-group'><button onclick='refreshSerialPorts()'>Refresh Serial</button><button onclick='refreshHidDevices()'>Refresh HID</button></div></div><div class='control-group'><h3>System</h3><div class='button-group'><button onclick=\"window.location.href='/setup'\">Plex Setup</button><button onclick=\"window.location.href='/logs'\">View Logs</button><select id=\"rating-filter\" style=\"padding: 5px;\"><option value=\"all\">All Age Ratings</option>{% for rating in ratings %}<option value=\"{{ rating }}\">{{ rating }}</option>{% endfor %}</select><button id=\"pdf-start-button\" onclick=\"startPdfGeneration()\">Start PDF Generation</button><a href=\"/stop_pdf_generation\" id=\"pdf-stop-button\" class=\"button-link\" style=\"display:none; background-color: #dc3545;\">Force Stop</a><a href=\"{{ url_for('logout') }}\" class=\"button-link\">Logout</a></div><p id=\"pdf-status-text\" style=\"margin-top:10px;\"></p><div id=\"pdf-links-container\" style=\"margin-top: 10px;\"></div></div></div><div class='search-container'><input type='text' id='search-input' placeholder='Search by title...' value='{{ search_term }}' oninput='debounceSearch()'><select id='genre-filter' onchange='applyGenreFilter()'><option value=''>All Genres</option>{% for genre in genres %}<option value='{{ genre }}' {% if genre == genre_filter %}selected{% endif %}>{{ genre }}</option>{% endfor %}</select><button onclick='clearSearch()'>Clear</button></div><table><thead><tr><th>Title</th><th>Year</th><th>Type</th><th>Director</th><th>Actors</th><th>Barcode</th><th>Actions</th></tr></thead><tbody>{% for item in items %}<tr><td>{{ item.title }}</td><td>{{ item.year }}</td><td>{{ item.type }}</td><td>{% for director in item.directors %}<a href=\"/director/{{ director|urlencode }}\">{{ director }}</a>{% endfor %}</td><td>{% for actor in item.actors %}<a href=\"/actor/{{ actor|urlencode }}\">{{ actor }}</a><br>{% endfor %}</td><td><span id='barcode-{{ item.rating_key }}'>{{ item.barcode }}</span><form style='display:none' id='edit-form-{{ item.rating_key }}'><input type='text' name='barcode' value='{{ item.barcode }}' pattern='\\d{12,13}' title='Barcode must be 12 or 13 digits' required><button type='submit'>Save</button><button type='button' onclick=\"toggleEdit('{{ item.rating_key }}')\">Cancel</button></form></td><td><button onclick=\"playMedia('{{ item.rating_key }}')\">Play</button><button onclick=\"togglePoster('{{ item.rating_key }}')\">Poster</button><a class='button-link' href='/poster/{{ item.rating_key }}?download=true' download>Download</a><button onclick=\"toggleEdit('{{ item.rating_key }}')\">Edit Barcode</button><div id='poster-container-{{ item.rating_key }}' style='display:none;margin-top:10px;'><img id='poster-{{ item.rating_key }}' data-src='/poster/{{ item.rating_key }}' style='max-width:200px;' loading='lazy'></div></td></tr>{% endfor %}</tbody></table><div class='pagination'><button onclick=\"window.location.href='/?page={{ page - 1 }}&per_page={{ per_page }}{% if search_term %}&search={{ search_term }}{% endif %}{% if genre_filter %}&genre={{ genre_filter }}{% endif %}'\" {% if page <= 1 %}disabled{% endif %}>Prev</button><span>Page {{ page }} of {{ total_pages }} | Total items: {{ total_items }}</span><button onclick=\"window.location.href='/?page={{ page + 1 }}&per_page={{ per_page }}{% if search_term %}&search={{ search_term }}{% endif %}{% if genre_filter %}&genre={{ genre_filter }}{% endif %}'\" {% if page >= total_pages %}disabled{% endif %}>Next</button></div><script>document.addEventListener('DOMContentLoaded',()=>{document.querySelectorAll('input[name=\"scanner_mode\"]').forEach(radio=>radio.addEventListener('change',toggleScannerInputs));toggleScannerInputs();const eventSource=new EventSource('/stream');eventSource.onmessage=function(event){const data=JSON.parse(event.data);document.getElementById('status-box').textContent=data.message;};const themeToggle=document.getElementById('theme-toggle');themeToggle.addEventListener('click',()=>{let isDark=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',isDark?'dark':'light');updateThemeIcon(isDark)});if(localStorage.getItem('theme')==='dark'||!localStorage.getItem('theme')&&window.matchMedia('(prefers-color-scheme: dark)').matches){document.body.classList.add('dark-mode');updateThemeIcon(true)}checkPdfStatus();document.querySelectorAll('form[id^=\"edit-form-\"]').forEach(form=>{form.addEventListener('submit',function(e){e.preventDefault();const ratingKey=this.id.split('-').pop();fetch('/edit_barcode/'+ratingKey,{method:'POST',body:new FormData(this)}).then(res=>res.json()).then(data=>{if(data.error){alert('Error: '+data.error)}else{document.getElementById('barcode-'+ratingKey).textContent=new FormData(this).get('barcode');if(document.getElementById('poster-'+ratingKey).parentElement.style.display!=='none'){document.getElementById('poster-'+ratingKey).src='/poster/'+ratingKey+'?t='+(new Date).getTime()}toggleEdit(ratingKey);alert(data.message)}}).catch(err=>alert('Error: '+err.message))})});populateSelect('client_select',{{ clients|tojson }},'{{ last_client }}');populateSelect('serial_device_select',{{ serial_ports|tojson }},'{{ scanner_device }}');populateHidSelect('hid_device_select',{{ hid_devices|tojson }},'{{ scanner_device }}');});function updateThemeIcon(isDark){const themeToggle=document.getElementById('theme-toggle');themeToggle.textContent=isDark?'🌙':'☀️'}function checkPdfStatus(){const pdfStatusText=document.getElementById('pdf-status-text');const pdfStartButton=document.getElementById('pdf-start-button');const pdfLinksContainer=document.getElementById('pdf-links-container');const pdfStopButton=document.getElementById('pdf-stop-button');let pdfStatusInterval=null;fetch('/pdf_status').then(e=>e.json()).then(e=>{pdfLinksContainer.innerHTML='';if(e.status==='running'){pdfStatusText.textContent='Status: Generating PDFs...';pdfStatusText.style.color='orange';pdfStartButton.style.display='none';pdfStopButton.style.display='inline-block';if(!pdfStatusInterval){pdfStatusInterval=setInterval(checkPdfStatus,5000)}}else{pdfStopButton.style.display='none';if(e.status==='complete'){pdfStatusText.textContent='Status: Generation Complete!';pdfStatusText.style.color='green';pdfStartButton.style.display='inline-block';fetch('/get_pdf_files').then(r=>r.json()).then(files=>{if(files.length>0){pdfLinksContainer.innerHTML='<strong>Downloads:</strong><br>';files.forEach(file=>{const link=document.createElement('a');link.href='/static/generated_pdfs/'+file;link.textContent=file;link.className='button-link';link.download=true;pdfLinksContainer.appendChild(link);pdfLinksContainer.appendChild(document.createElement('br'))})}})}else if(e.status.startsWith('error')){pdfStatusText.textContent='Status: '+e.status;pdfStatusText.style.color='red';pdfStartButton.style.display='inline-block'}else{pdfStatusText.textContent='';pdfStartButton.style.display='inline-block'}clearInterval(pdfStatusInterval);pdfStatusInterval=null}})}function toggleScannerInputs(){const mode=document.querySelector('input[name=\"scanner_mode\"]:checked').value;document.getElementById('serial-group').style.display=mode==='serial'?'block':'none';document.getElementById('hid-group').style.display=mode==='hid'?'block':'none'}function togglePoster(ratingKey){const container=document.getElementById('poster-container-'+ratingKey);const img=document.getElementById('poster-'+ratingKey);if(container.style.display==='none'){img.src=img.dataset.src;container.style.display='block'}else{container.style.display='none'}}function toggleEdit(ratingKey){const span=document.getElementById('barcode-'+ratingKey);const form=document.getElementById('edit-form-'+ratingKey);if(span.style.display==='none'){span.style.display='inline';form.style.display='none'}else{span.style.display='none';form.style.display='inline-block'}}function playMedia(ratingKey){fetch('/play/'+ratingKey,{method:'POST'}).then(res=>{if(!res.ok){res.text().then(text=>alert('Error: '+text))}}).catch(err=>alert('Error: '+err.message))}function refreshClients(){fetch('/refresh_clients',{method:'POST'}).then(res=>res.json()).then(data=>{if(data.error){alert('Error: '+data.error);return}const select=document.getElementById('client_select');populateSelect(select.id,data.clients,select.value);alert('Client list refreshed!')}).catch(err=>alert('Error: '+err.message))}function refreshSerialPorts(){fetch('/refresh_serial_ports',{method:'POST'}).then(res=>res.json()).then(data=>{if(data.error){alert('Error: '+data.error);return}const select=document.getElementById('serial_device_select');populateSelect(select.id,data.ports,select.value);alert('Serial port list refreshed!')}).catch(err=>alert('Error: '+err.message))}function refreshHidDevices(){fetch('/refresh_hid_devices',{method:'POST'}).then(res=>res.json()).then(data=>{if(data.error){alert('Error: '+data.error);return}const select=document.getElementById('hid_device_select');populateHidSelect(select.id,data.devices,select.value);alert('HID device list refreshed!')}).catch(err=>alert('Error: '+err.message))}function startPdfGeneration(){const selectedRating=document.getElementById('rating-filter').value;const url='/start_pdf_generation?rating='+encodeURIComponent(selectedRating);window.location.href=url}function clearSearch(){window.location.href='/?page=1&per_page={{ per_page }}'}function populateSelect(selectId,options,selectedValue){const select=document.getElementById(selectId);const currentVal=select.value;select.innerHTML='<option value=\"\">Select a Device</option>';options.forEach(opt=>{const option=document.createElement('option');option.value=opt;option.textContent=opt;if(opt===selectedValue||opt===currentVal){option.selected=true}select.appendChild(option)})}function populateHidSelect(selectId,options,selectedValue){const select=document.getElementById(selectId);select.innerHTML='';options.forEach(opt=>{const option=document.createElement('option');option.value=opt.path;option.textContent=opt.name;if(opt.path===selectedValue){option.selected=true}select.appendChild(option)})}</script></body></html>" > templates/index.html

# ----------------------------------------------------------------------
# -------- 7. Other HTML Templates & CSS -------------------------------
# ----------------------------------------------------------------------
echo "[7/9] Creating other HTML templates and CSS..."
echo "<!DOCTYPE html><html><head><title>Plex Barcode Dashboard - Logs</title><link rel=\"stylesheet\" href=\"{{ url_for('static', filename='style.css') }}\"></head><body><h1>Plex Barcode Dashboard Logs <button id=\"theme-toggle\">☀️</button></h1><div class='log-container'><p><a href='/' class='button-link'>Back to Dashboard</a></p><div class='log-controls'><span>Show logs from last:</span><a href='/logs?days=1' class='button-link {% if current_days == \"1\" %}active{% endif %}'>1 Day</a><a href='/logs?days=3' class='button-link {% if current_days == \"3\" %}active{% endif %}'>3 Days</a><a href='/logs?days=7' class='button-link {% if current_days == \"7\" %}active{% endif %}'>7 Days</a><a href='/logs?days=all' class='button-link {% if current_days == \"all\" %}active{% endif %}'>All Time</a></div><table><thead><tr><th>Timestamp</th><th>Source</th><th>Message</th></tr></thead><tbody>{% for log in logs %}<tr><td>{{ log.timestamp }}</td><td>{{ log.source }}</td><td>{{ log.message }}</td></tr>{% else %}<tr><td colspan=3>No log entries found for this period.</td></tr>{% endfor %}</tbody></table></div><script>document.getElementById('theme-toggle').addEventListener('click',()=>{let e=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',e?'dark':'light');updateThemeIcon(e)});function updateThemeIcon(e){document.getElementById('theme-toggle').textContent=e?'🌙':'☀️'}if(localStorage.getItem('theme')==='dark'||!localStorage.getItem('theme')&&window.matchMedia('(prefers-color-scheme: dark)').matches){document.body.classList.add('dark-mode');updateThemeIcon(true)}</script></body></html>" > templates/logs.html
echo "<!DOCTYPE html><html><head><title>Search Results</title><link rel=\"stylesheet\" href=\"{{ url_for('static', filename='style.css') }}\"></head><body><h1>Results for {{ query_type }}: \"{{ query }}\" <button id=\"theme-toggle\">☀️</button></h1><p><a href='/' class='button-link'>Back to Dashboard</a></p><table><thead><tr><th>Title</th><th>Year</th><th>Type</th></tr></thead><tbody>{% for item in results %}<tr><td>{{ item.title }}</td><td>{{ item.year }}</td><td>{{ item.type }}</td></tr>{% else %}<tr><td colspan='3'>No results found in your library.</td></tr>{% endfor %}</tbody></table><script>document.getElementById('theme-toggle').addEventListener('click',()=>{let e=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',e?'dark':'light');updateThemeIcon(e)});function updateThemeIcon(e){document.getElementById('theme-toggle').textContent=e?'🌙':'☀️'}if(localStorage.getItem('theme')==='dark'||!localStorage.getItem('theme')&&window.matchMedia('(prefers-color-scheme: dark)').matches){document.body.classList.add('dark-mode');updateThemeIcon(true)}</script></body></html>" > templates/results.html
echo "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;margin:20px;background:#f5f5f5;color:#212529;transition:background-color .3s,color .3s;}h1{display:flex;justify-content:space-between;align-items:center;}table{width:100%;border-collapse:collapse;margin-top:20px;}th,td{border:1px solid #ddd;padding:8px;text-align:left;}th{background-color:#007BFF;color:white;cursor:pointer;}tr:nth-child(even){background-color:#f2f2f2;}tr:hover{background-color:#e0e0e0;}button,a.button-link{padding:6px 12px;background:#0056b3;color:white;border:none;border-radius:4px;cursor:pointer;text-decoration:none;margin:2px;transition:all .2s;}button:hover,a.button-link:hover{background:#003d80;transform:scale(1.05);}.controls-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(350px,1fr));gap:20px;margin-bottom:20px;}.control-group{background:white;padding:15px;border:1px solid #ccc;border-radius:5px;}.control-group h3{margin-top:0;}.control-group form,.control-group .button-group{display:flex;align-items:center;gap:10px;flex-wrap:wrap;}select,input[type='text'],input[type='number']{padding:8px;font-size:14px;border:1px solid #ccc;border-radius:4px;background:white;}.search-container{margin-bottom:20px;display:flex;gap:10px;flex-wrap:wrap;}.pagination{margin-top:20px;text-align:center;}.pagination button{margin:0 5px;}.pagination button:disabled{opacity:.5;cursor:not-allowed;}.radio-group label{margin-right:15px;}.flash{padding:10px;margin-bottom:10px;border-radius:4px;}.flash.info{background-color:#d1ecf1;border-color:#bee5eb;color:#0c5460;}.flash.warning{background-color:#fff3cd;border-color:#ffeeba;color:#856404;}#theme-toggle{font-size:24px;background:none;border:none;cursor:pointer;}#status-box{background-color:#eee;padding:10px;border-radius:4px;min-height:24px;font-family:monospace;white-space:pre-wrap;}.form-container{max-width:500px;margin:0 auto;padding:20px;border:1px solid #ccc;border-radius:5px;background:white;}body.dark-mode{background-color:#121212;color:#e0e0e0;}body.dark-mode .control-group,body.dark-mode .form-container{background-color:#1e1e1e;border-color:#444;}body.dark-mode table{color:#e0e0e0;}body.dark-mode th,body.dark-mode td{border-color:#444;}body.dark-mode tr:nth-child(even){background-color:#2c2c2c;}body.dark-mode tr:hover{background-color:#383838;}body.dark-mode select,body.dark-mode input[type='text'],body.dark-mode input[type='number']{background-color:#333;color:white;border-color:#555;}body.dark-mode #status-box{background-color:#333;}body.dark-mode a{color:#8ab4f8;}" > static/style.css

# ----------------------------------------------------------------------
# -------- 8. Barcode Listener -----------------------------------------
# ----------------------------------------------------------------------
echo "[8/9] Creating barcode_listener.py..."
echo "import sqlite3" > barcode_listener.py
echo "import serial" >> barcode_listener.py
echo "import time" >> barcode_listener.py
echo "import os" >> barcode_listener.py
echo "import requests" >> barcode_listener.py
echo "import json" >> barcode_listener.py
echo "import evdev" >> barcode_listener.py
echo "from evdev import ecodes" >> barcode_listener.py
echo "from plexapi.server import PlexServer" >> barcode_listener.py
echo "import pychromecast" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')" >> barcode_listener.py
echo "PLEX_APP_ID = '9AC19493'" >> barcode_listener.py
echo "WEB_URL = 'http://127.0.0.1:5000'" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "SCAN_CODES = {" >> barcode_listener.py
echo "    0: None, 1: u'ESC', 2: u'1', 3: u'2', 4: u'3', 5: u'4', 6: u'5', 7: u'6', 8: u'7', 9: u'8', 10: u'9', 11: u'0'," >> barcode_listener.py
echo "    12: u'-', 13: u'=', 14: u'BKSP', 15: u'TAB', 16: u'q', 17: u'w', 18: u'e', 19: u'r', 20: u't', 21: u'y', 22: u'u'," >> barcode_listener.py
echo "    23: u'i', 24: u'o', 25: u'p', 26: u'[', 27: u']', 28: u'CRLF', 29: u'LCTRL', 30: u'a', 31: u's', 32: u'd', 33: u'f'," >> barcode_listener.py
echo "    34: u'g', 35: u'h', 36: u'j', 37: u'k', 38: u'l', 39: u';', 40: u'\'', 41: u'\`', 42: u'LSHFT', 43: u'\\\\'," >> barcode_listener.py
echo "    44: u'z', 45: u'x', 46: u'c', 47: u'v', 48: u'b', 49: u'n', 50: u'm', 51: u',', 52: u'.', 53: u'/', 54: u'RSHFT'," >> barcode_listener.py
echo "    56: u'LALT', 57: u' ', 100: u'RALT'" >> barcode_listener.py
echo "}" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def get_db():" >> barcode_listener.py
echo "    conn = sqlite3.connect(DB_PATH, timeout=20)" >> barcode_listener.py
echo "    conn.execute('PRAGMA journal_mode=WAL')" >> barcode_listener.py
echo "    conn.row_factory = sqlite3.Row" >> barcode_listener.py
echo "    return conn" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def log(msg, source='listener'):" >> barcode_listener.py
echo "    print(f'[{source.upper()}] {msg}', flush=True)" >> barcode_listener.py
echo "    try:" >> barcode_listener.py
echo "        with get_db() as conn:" >> barcode_listener.py
echo "            conn.execute('INSERT INTO logs (source, message) VALUES (?, ?)', (source, msg))" >> barcode_listener.py
echo "            conn.commit()" >> barcode_listener.py
echo "    except Exception as e:" >> barcode_listener.py
echo "        print(f'Database logging failed: {e}', flush=True)" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def post_status_update(message):" >> barcode_listener.py
echo "    try:" >> barcode_listener.py
echo "        requests.post(f'{WEB_URL}/publish_status', json={'message': message}, timeout=2)" >> barcode_listener.py
echo "    except requests.exceptions.RequestException as e:" >> barcode_listener.py
echo "        log(f'Could not post status update to web UI: {e}')" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def get_scanner_settings():" >> barcode_listener.py
echo "    with get_db() as conn:" >> barcode_listener.py
echo "        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN (\"scanner_mode\", \"scanner_device\")')}" >> barcode_listener.py
echo "        return settings.get('scanner_mode', 'serial'), settings.get('scanner_device', '/dev/ttyACM0')" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def get_plex_settings():" >> barcode_listener.py
echo "    with get_db() as conn:" >> barcode_listener.py
echo "        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN (\"plex_protocol\", \"plex_url\", \"plex_port\", \"plex_token\", \"tmdb_api_key\")')}" >> barcode_listener.py
echo "        return settings" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def get_plex_server():" >> barcode_listener.py
echo "    settings = get_plex_settings()" >> barcode_listener.py
echo "    if not all(k in settings for k in ['plex_protocol', 'plex_url', 'plex_port', 'plex_token']):" >> barcode_listener.py
echo "        log('Incomplete Plex settings')" >> barcode_listener.py
echo "        return None" >> barcode_listener.py
echo "    try:" >> barcode_listener.py
echo "        plex_url = f\"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}\"" >> barcode_listener.py
echo "        return PlexServer(plex_url, settings['plex_token'])" >> barcode_listener.py
echo "    except Exception as e:" >> barcode_listener.py
echo "        log(f'Failed to connect to Plex server: {e}')" >> barcode_listener.py
echo "        return None" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def get_media_info_from_db(barcode):" >> barcode_listener.py
echo "    with get_db() as conn:" >> barcode_listener.py
echo "        row = conn.execute('SELECT rating_key FROM barcodes WHERE barcode = ?', (barcode,)).fetchone()" >> barcode_listener.py
echo "        return row['rating_key'] if row else None" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def lookup_barcode_on_tmdb(barcode):" >> barcode_listener.py
echo "    settings = get_plex_settings()" >> barcode_listener.py
echo "    api_key = settings.get('tmdb_api_key')" >> barcode_listener.py
echo "    if not api_key: return" >> barcode_listener.py
echo "    log(f'Barcode not in local DB. Searching TMDB for {barcode}...')" >> barcode_listener.py
echo "    try:" >> barcode_listener.py
echo "        search_codes = [barcode, barcode.lstrip('0')]" >> barcode_listener.py
echo "        for code in set(search_codes):" >> barcode_listener.py
echo "            url = f'https://api.themoviedb.org/3/find/{code}?external_source=ean&api_key={api_key}'" >> barcode_listener.py
echo "            response = requests.get(url, timeout=5)" >> barcode_listener.py
echo "            response.raise_for_status()" >> barcode_listener.py
echo "            data = response.json()" >> barcode_listener.py
echo "            results = data.get('movie_results', []) + data.get('tv_results', [])" >> barcode_listener.py
echo "            if results:" >> barcode_listener.py
echo "                title = results[0].get('title') or results[0].get('name')" >> barcode_listener.py
echo "                log(f'Scanned barcode {barcode} is for \"{title}\", which is not in the Plex library.')" >> barcode_listener.py
echo "                post_status_update(f'Scanned: \"{title}\" (Not in Library)')" >> barcode_listener.py
echo "                return" >> barcode_listener.py
echo "    except Exception as e:" >> barcode_listener.py
echo "        log(f'Error querying TMDB: {e}')" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def get_selected_target():" >> barcode_listener.py
echo "    with get_db() as conn:" >> barcode_listener.py
echo "        row = conn.execute('SELECT value FROM settings WHERE key = \"last_client\"').fetchone()" >> barcode_listener.py
echo "        return row['value'] if row else None" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def play_media_on_device(rating_key, plex_server, target_device_name):" >> barcode_listener.py
echo "    try:" >> barcode_listener.py
echo "        media = plex_server.fetchItem(int(rating_key))" >> barcode_listener.py
echo "        if not media: " >> barcode_listener.py
echo "            log(f'No media found for rating_key {rating_key}')" >> barcode_listener.py
echo "            return" >> barcode_listener.py
echo "        post_status_update(f'Playing \"{media.title}\" on {target_device_name}')" >> barcode_listener.py
echo "        is_chromecast = False" >> barcode_listener.py
echo "        try:" >> barcode_listener.py
echo "            casts, _ = pychromecast.get_listed_chromecasts(friendly_names=[target_device_name])" >> barcode_listener.py
echo "            if casts: is_chromecast = True" >> barcode_listener.py
echo "        except Exception: log('Chromecast discovery failed.')" >> barcode_listener.py
echo "        max_retries = 3" >> barcode_listener.py
echo "        retry_delay = 3" >> barcode_listener.py
echo "        for attempt in range(max_retries):" >> barcode_listener.py
echo "            try:" >> barcode_listener.py
echo "                if not is_chromecast:" >> barcode_listener.py
echo "                    log(f'Attempting playback on {target_device_name} (attempt {attempt + 1}/{max_retries})...')" >> barcode_listener.py
echo "                    client = plex_server.client(target_device_name)" >> barcode_listener.py
echo "                    client.playMedia(media)" >> barcode_listener.py
echo "                    log(f'Playback command sent for \"{media.title}\" to {target_device_name}.')" >> barcode_listener.py
echo "                else:" >> barcode_listener.py
echo "                    log(f'Attempting Chromecast playback on {target_device_name} (attempt {attempt + 1}/{max_retries})...')" >> barcode_listener.py
echo "                    plex_client = None" >> barcode_listener.py
echo "                    casts[0].wait()" >> barcode_listener.py
echo "                    target_uuid = str(casts[0].cast_info.uuid).replace('-', '')" >> barcode_listener.py
echo "                    if casts[0].app_id != '9AC19493':" >> barcode_listener.py
echo "                        log('Plex app is not running. Launching app...')" >> barcode_listener.py
echo "                        casts[0].start_app('9AC19493')" >> barcode_listener.py
echo "                        for _ in range(10):" >> barcode_listener.py
echo "                            time.sleep(2)" >> barcode_listener.py
echo "                            try:" >> barcode_listener.py
echo "                                for c in plex_server.clients():" >> barcode_listener.py
echo "                                    if c.machineIdentifier == target_uuid: plex_client = c; break" >> barcode_listener.py
echo "                                if plex_client: break" >> barcode_listener.py
echo "                            except Exception: pass" >> barcode_listener.py
echo "                    if not plex_client:" >> barcode_listener.py
echo "                        for c in plex_server.clients():" >> barcode_listener.py
echo "                            if c.machineIdentifier == target_uuid: plex_client = c; break" >> barcode_listener.py
echo "                    if plex_client:" >> barcode_listener.py
echo "                        client_name = getattr(plex_client, \"name\", plex_client.title)" >> barcode_listener.py
echo "                        log(f'UUID match found! Client name is \"{client_name}\".')" >> barcode_listener.py
echo "                        plex_client.playMedia(media)" >> barcode_listener.py
echo "                    else:" >> barcode_listener.py
echo "                        raise ConnectionError('Could not find a matching Chromecast client on Plex Server after wake-up.')" >> barcode_listener.py
echo "                return" >> barcode_listener.py
echo "            except requests.exceptions.ConnectionError as e:" >> barcode_listener.py
echo "                log(f'Playback failed on attempt {attempt + 1}: Connection refused or failed.')" >> barcode_listener.py
echo "                if attempt < max_retries - 1:" >> barcode_listener.py
echo "                    log(f'Retrying in {retry_delay} seconds...')" >> barcode_listener.py
echo "                    time.sleep(retry_delay)" >> barcode_listener.py
echo "                else:" >> barcode_listener.py
echo "                    log('All playback attempts failed.')" >> barcode_listener.py
echo "            except Exception as e:" >> barcode_listener.py
echo "                log(f'An unexpected error occurred during playback: {e}')" >> barcode_listener.py
echo "                return" >> barcode_listener.py
echo "    except Exception as e: log(f'Top-level playback error: {e}')" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def handle_barcode(barcode):" >> barcode_listener.py
echo "    log(f'Received barcode: {barcode}')" >> barcode_listener.py
echo "    plex_server = get_plex_server()" >> barcode_listener.py
echo "    if not plex_server: log('No Plex server connection'); return" >> barcode_listener.py
echo "    rating_key = get_media_info_from_db(barcode)" >> barcode_listener.py
echo "    if not rating_key:" >> barcode_listener.py
echo "        log(f'No media found for barcode: {barcode}')" >> barcode_listener.py
echo "        lookup_barcode_on_tmdb(barcode)" >> barcode_listener.py
echo "        return" >> barcode_listener.py
echo "    try:" >> barcode_listener.py
echo "        item = plex_server.fetchItem(int(rating_key))" >> barcode_listener.py
echo "        post_status_update(f'Scanned: {item.title}')" >> barcode_listener.py
echo "    except Exception as e:" >> barcode_listener.py
echo "        log(f'Could not fetch item title for {rating_key}: {e}')" >> barcode_listener.py
echo "        post_status_update(f'Scanned barcode {barcode}')" >> barcode_listener.py
echo "    target_device = get_selected_target()" >> barcode_listener.py
echo "    if target_device: play_media_on_device(rating_key, plex_server, target_device)" >> barcode_listener.py
echo "    else: log('No client selected for playback')" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def listen_serial(device_path):" >> barcode_listener.py
echo "    log(f'Starting SERIAL listener on {device_path}')" >> barcode_listener.py
echo "    while True:" >> barcode_listener.py
echo "        try:" >> barcode_listener.py
echo "            with serial.Serial(device_path, 9600, timeout=1) as ser:" >> barcode_listener.py
echo "                log(f'Successfully opened serial port {device_path}')" >> barcode_listener.py
echo "                while True:" >> barcode_listener.py
echo "                    line = ser.readline().decode('utf-8', errors='ignore').strip()" >> barcode_listener.py
echo "                    if line: handle_barcode(line)" >> barcode_listener.py
echo "        except serial.SerialException as e:" >> barcode_listener.py
echo "            log(f'Serial error on {device_path}: {e}. Retrying in 5 seconds...')" >> barcode_listener.py
echo "            time.sleep(5)" >> barcode_listener.py
echo "        except Exception as e:" >> barcode_listener.py
echo "            log(f'Unexpected error in serial listener: {e}. Retrying in 5 seconds...')" >> barcode_listener.py
echo "            time.sleep(5)" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def listen_hid(device_path):" >> barcode_listener.py
echo "    log(f'Starting HID listener on {device_path}')" >> barcode_listener.py
echo "    while True:" >> barcode_listener.py
echo "        try:" >> barcode_listener.py
echo "            device = evdev.InputDevice(device_path)" >> barcode_listener.py
echo "            log(f'Successfully opened HID device {device.name} at {device_path}.')" >> barcode_listener.py
echo "            barcode = ''" >> barcode_listener.py
echo "            for event in device.read_loop():" >> barcode_listener.py
echo "                if event.type == ecodes.EV_KEY and event.value == 1:" >> barcode_listener.py
echo "                    key = SCAN_CODES.get(event.code)" >> barcode_listener.py
echo "                    if key == 'CRLF':" >> barcode_listener.py
echo "                        if barcode: handle_barcode(barcode)" >> barcode_listener.py
echo "                        barcode = ''" >> barcode_listener.py
echo "                    elif key and len(key) == 1 and key.isdigit():" >> barcode_listener.py
echo "                        barcode += key" >> barcode_listener.py
echo "        except (IOError, OSError) as e:" >> barcode_listener.py
echo "            log(f'HID error on {device_path}: {e}. Retrying in 5 seconds...')" >> barcode_listener.py
echo "            time.sleep(5)" >> barcode_listener.py
echo "        except Exception as e:" >> barcode_listener.py
echo "            log(f'Unexpected error in HID listener: {e}. Retrying in 5 seconds...')" >> barcode_listener.py
echo "            time.sleep(5)" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "def main():" >> barcode_listener.py
echo "    log('Starting barcode listener service...')" >> barcode_listener.py
echo "    mode, device = get_scanner_settings()" >> barcode_listener.py
echo "    if mode == 'serial':" >> barcode_listener.py
echo "        listen_serial(device)" >> barcode_listener.py
echo "    elif mode == 'hid':" >> barcode_listener.py
echo "        listen_hid(device)" >> barcode_listener.py
echo "    else:" >> barcode_listener.py
echo "        log(f'Unknown scanner mode: {mode}')" >> barcode_listener.py
echo "" >> barcode_listener.py
echo "if __name__ == '__main__':" >> barcode_listener.py
echo "    main()" >> barcode_listener.py

# ----------------------------------------------------------------------
# -------- 9. Setup Systemd Services -----------------------------------
# ----------------------------------------------------------------------
echo "[9/9] Setting up systemd services..."
echo "[Unit]" > /tmp/plex-barcode-web.service
echo "Description=Plex Barcode Remote Web Dashboard" >> /tmp/plex-barcode-web.service
echo "After=network.target redis-server.service" >> /tmp/plex-barcode-web.service
echo "Requires=redis-server.service" >> /tmp/plex-barcode-web.service
echo "" >> /tmp/plex-barcode-web.service
echo "[Service]" >> /tmp/plex-barcode-web.service
echo "User=$USER" >> /tmp/plex-barcode-web.service
echo "Group=$(id -gn $USER)" >> /tmp/plex-barcode-web.service
echo "WorkingDirectory=$PROJECT_DIR" >> /tmp/plex-barcode-web.service
echo "Environment=\"FLASK_PORT=$FLASK_PORT\"" >> /tmp/plex-barcode-web.service
echo "ExecStart=$PROJECT_DIR/venv/bin/python $PROJECT_DIR/web_dashboard.py" >> /tmp/plex-barcode-web.service
echo "Restart=always" >> /tmp/plex-barcode-web.service
echo "RestartSec=10" >> /tmp/plex-barcode-web.service
echo "" >> /tmp/plex-barcode-web.service
echo "[Install]" >> /tmp/plex-barcode-web.service
echo "WantedBy=multi-user.target" >> /tmp/plex-barcode-web.service
sudo mv /tmp/plex-barcode-web.service /etc/systemd/system/plex-barcode-web.service
sudo chmod 644 /etc/systemd/system/plex-barcode-web.service

echo "[Unit]" > /tmp/plex-barcode-listener.service
echo "Description=Plex Barcode Remote Listener" >> /tmp/plex-barcode-listener.service
echo "After=network.target plex-barcode-web.service" >> /tmp/plex-barcode-listener.service
echo "" >> /tmp/plex-barcode-listener.service
echo "[Service]" >> /tmp/plex-barcode-listener.service
echo "User=$USER" >> /tmp/plex-barcode-listener.service
echo "Group=input" >> /tmp/plex-barcode-listener.service
echo "WorkingDirectory=$PROJECT_DIR" >> /tmp/plex-barcode-listener.service
echo "ExecStart=$PROJECT_DIR/venv/bin/python $PROJECT_DIR/barcode_listener.py" >> /tmp/plex-barcode-listener.service
echo "Restart=always" >> /tmp/plex-barcode-listener.service
echo "RestartSec=10" >> /tmp/plex-barcode-listener.service
echo "" >> /tmp/plex-barcode-listener.service
echo "[Install]" >> /tmp/plex-barcode-listener.service
echo "WantedBy=multi-user.target" >> /tmp/plex-barcode-listener.service
sudo mv /tmp/plex-barcode-listener.service /etc/systemd/system/plex-barcode-listener.service
sudo chmod 644 /etc/systemd/system/plex-barcode-listener.service

# NEW: Add a udev rule to ensure the user can access input devices
echo "[10/10] Adding udev rule for input device permissions..."
echo 'KERNEL=="event*", SUBSYSTEM=="input", MODE="0660", GROUP="input"' | sudo tee /etc/udev/rules.d/99-input-permissions.rules > /dev/null
sudo usermod -a -G input $USER

sudo systemctl enable --now redis-server
sudo systemctl daemon-reload
sudo systemctl enable plex-barcode-web.service
sudo systemctl enable plex-barcode-listener.service
sudo systemctl restart plex-barcode-web.service
sudo systemctl restart plex-barcode-listener.service

echo "=== Installation complete! ==="
echo "Access the dashboard at http://$(hostname -I | cut -d' ' -f1):$FLASK_PORT"
echo "A REBOOT IS HIGHLY RECOMMENDED for all permission changes to take effect."
echo "Use 'sudo systemctl status plex-barcode-web' and 'sudo systemctl status plex-barcode-listener' to check service status."
