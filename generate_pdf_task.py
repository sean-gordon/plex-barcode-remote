import os
import sqlite3
import io
import random
import time
import shutil
import gc
import sys
import json
from plexapi.server import PlexServer
from PIL import Image, ImageDraw
import barcode
from barcode.writer import ImageWriter
import requests
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.expanduser('~/.config/plex_barcode_remote/poster_cache')
OUTPUT_DIR = os.path.join(PROJECT_DIR, 'static', 'generated_pdfs')
STATUS_FILE = os.path.join(PROJECT_DIR, 'static', 'pdf_status.txt')
FILES_JSON = os.path.join(PROJECT_DIR, 'static', 'pdf_files.json')
PID_FILE = os.path.join(PROJECT_DIR, 'static', 'pdf_task.pid')
BATCH_SIZE = 25
POSTER_WIDTH = 300
POSTER_HEIGHT = 450

def log(msg, source='pdf_task'):
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

def get_plex_server():
    with get_db() as conn:
        settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN ("plex_protocol", "plex_url", "plex_port", "plex_token")')}
    if not all(k in settings for k in ['plex_protocol', 'plex_url', 'plex_port', 'plex_token']):
        return None
    try:
        plex_url = f"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}"
        session = requests.Session()
        session.verify = False
        return PlexServer(plex_url, settings['plex_token'], session=session)
    except Exception as e:
        log(f'Failed to connect to Plex server: {e}')
        return None

def get_or_create_barcode(rating_key, media_type):
    with get_db() as conn:
        row = conn.execute('SELECT barcode FROM barcodes WHERE rating_key = ?', (rating_key,)).fetchone()
        if row: return row['barcode']
        new_code = ''.join(str(random.randint(0, 9)) for _ in range(12))
        try:
            conn.execute('INSERT INTO barcodes (rating_key, barcode, media_type) VALUES (?, ?, ?)', (rating_key, new_code, media_type))
            conn.commit()
        except sqlite3.IntegrityError:
            return get_or_create_barcode(rating_key, media_type)
        return new_code

def get_cached_poster(item_dict, plex):
    rating_key = item_dict['rating_key']
    thumb_url = item_dict['thumb']
    title = item_dict['title']
    cache_path = os.path.join(CACHE_DIR, f'{rating_key}.jpg')
    if os.path.exists(cache_path):
        with open(cache_path, 'rb') as f: return f.read()
    if thumb_url:
        try:
            poster_url = plex.url(f'{thumb_url}?width={POSTER_WIDTH}&height={POSTER_HEIGHT}&opacity=100', includeToken=True)
            response = requests.get(poster_url, timeout=10)
            response.raise_for_status()
            image_data = response.content
            with open(cache_path, 'wb') as f: f.write(image_data)
            return image_data
        except requests.exceptions.RequestException as e:
            log(f"Cached thumb for '{title}' failed ({e}). Fetching live item for fresh URL.")
    try:
        live_item = plex.fetchItem(int(rating_key))
        log(f"Downloading poster for '{title}' with fresh URL.")
        fresh_poster_url = plex.url(f'{live_item.thumb}?width={POSTER_WIDTH}&height={POSTER_HEIGHT}&opacity=100', includeToken=True)
        response = requests.get(fresh_poster_url, timeout=15)
        response.raise_for_status()
        image_data = response.content
        with open(cache_path, 'wb') as f: f.write(image_data)
        return image_data
    except Exception as e:
        log(f"Final attempt to download poster for '{title}' failed: {e}")
        raise

def main():
    if len(sys.argv) > 1 and sys.argv[1] != 'all':
        selected_rating = sys.argv[1]
        log(f"PDF generation started for rating: '{selected_rating}'")
    else:
        selected_rating = None
        log("PDF generation started for all ratings.")
    shutil.rmtree(OUTPUT_DIR, ignore_errors=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)
    try:
        with open(STATUS_FILE, 'w') as f: f.write('running')
        plex = get_plex_server()
        if not plex: raise ConnectionError('Could not connect to Plex server.')
        log('Fetching media from local cache...')
        with get_db() as conn:
            query = 'SELECT rating_key, title, contentRating, media_type, thumb FROM media_items'
            params = []
            if selected_rating:
                query += ' WHERE contentRating = ?'
                params.append(selected_rating)
            media_rows = conn.execute(query, params).fetchall()
        if not media_rows:
            if selected_rating:
                raise ValueError(f"No media found with rating '{selected_rating}'. Run the sync script first.")
            else:
                raise ValueError('No media found in local cache. Run the sync script first.')
        lean_media_list = [dict(row) for row in media_rows]
        grouped_media = {}
        for item in lean_media_list:
            rating = item['contentRating']
            if rating not in grouped_media: grouped_media[rating] = []
            grouped_media[rating].append(item)
        if not grouped_media: raise ValueError('No media found after grouping.')
        generated_files = []
        for rating, items in grouped_media.items():
            for i in range(0, len(items), BATCH_SIZE):
                batch = items[i:i + BATCH_SIZE]
                part_num = (i // BATCH_SIZE) + 1
                log(f'  - Generating PDF part {part_num} for rating: {rating}')
                pdf = FPDF(orientation='P', unit='mm', format='A4')
                pdf.set_auto_page_break(False)
                pdf.add_page()
                card_w, card_h = 63, 88
                margin = 5
                cols = int((pdf.w - (2 * margin)) / card_w)
                rows = int((pdf.h - (2 * margin)) / card_h)
                x_start = (pdf.w - (cols * card_w)) / 2
                y_start = (pdf.h - (rows * card_h)) / 2
                x, y = x_start, y_start
                item_count = 0
                for item_dict in batch:
                    if item_count > 0 and item_count % (cols * rows) == 0:
                        pdf.add_page()
                        x, y = x_start, y_start
                    try:
                        poster_data = get_cached_poster(item_dict, plex)
                        poster_img = Image.open(io.BytesIO(poster_data))
                        barcode_value = get_or_create_barcode(str(item_dict['rating_key']), item_dict['media_type'])
                        ean = barcode.get('ean13', barcode_value, writer=ImageWriter())
                        barcode_buffer = io.BytesIO()
                        ean.write(barcode_buffer)
                        barcode_buffer.seek(0)
                        barcode_img = Image.open(barcode_buffer)
                        barcode_height = int(poster_img.height * 0.2)
                        content_img = Image.new('RGB', (poster_img.width, poster_img.height + barcode_height), (255, 255, 255))
                        content_img.paste(barcode_img.resize((poster_img.width, barcode_height)), (0, 0))
                        content_img.paste(poster_img, (0, barcode_height))
                        border_px, radius_px = 20, 45
                        final_size = (content_img.width + 2 * border_px, content_img.height + 2 * border_px)
                        background = Image.new('RGB', final_size, 'black')
                        background.paste(content_img, (border_px, border_px))
                        mask = Image.new('L', final_size, 0)
                        draw = ImageDraw.Draw(mask)
                        draw.rounded_rectangle((0, 0) + final_size, radius=radius_px, fill=255)
                        background.putalpha(mask)
                        card_buffer = io.BytesIO()
                        background.save(card_buffer, format='PNG')
                        card_buffer.seek(0)
                        pdf.image(card_buffer, x=x, y=y, w=card_w, h=card_h, type='PNG')
                        del poster_data, poster_img, barcode_img, content_img, background, mask, draw, card_buffer
                    except Exception as e:
                        log(f"Skipping '{item_dict['title']}' due to image error: {e}")
                        pdf.set_fill_color(230, 230, 230)
                        pdf.rect(x, y, card_w, card_h, 'F')
                        pdf.set_xy(x, y + card_h/2)
                        pdf.set_font('helvetica', 'B', 8)
                        pdf.multi_cell(card_w, 4, f"Error:\n{item_dict['title']}", align='C')
                    x += card_w
                    if (item_count + 1) % cols == 0:
                        x = x_start
                        y += card_h
                    item_count += 1
                    gc.collect()
                pdf_filename = f'Posters-{rating.replace("/", "_")}-part{part_num}.pdf'
                pdf_path = os.path.join(OUTPUT_DIR, pdf_filename)
                pdf.output(pdf_path)
                generated_files.append(pdf_filename)
        log(f'Generated {len(generated_files)} PDF files.')
        with open(FILES_JSON, 'w') as f:
            json.dump(generated_files, f)
        with open(STATUS_FILE, 'w') as f: f.write('complete')
    except Exception as e:
        log(f'Error during PDF generation: {e}')
        with open(STATUS_FILE, 'w') as f: f.write(f'error: {e}')
if __name__ == '__main__':
    main()


