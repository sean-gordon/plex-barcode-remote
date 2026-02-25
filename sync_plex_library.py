import os
import sqlite3
import json
import random
import requests
import urllib3
from plexapi.server import PlexServer
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

DB_PATH = os.path.expanduser('~/.config/plex_barcode_remote/barcodes.db')

def log(msg, conn, source='sync'):
    print(f'[{source.upper()}] {msg}', flush=True)
    try:
        conn.execute("INSERT INTO logs (source, message) VALUES (?, ?)", (source, msg))
        conn.commit()
    except Exception as e:
        print(f"Database logging failed: {e}", flush=True)

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.row_factory = sqlite3.Row
    return conn

def get_plex_server(conn):
    settings = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM settings WHERE key IN ("plex_protocol", "plex_url", "plex_port", "plex_token")')}
    if not all(k in settings for k in ['plex_protocol', 'plex_url', 'plex_port', 'plex_token']): return None
    try:
        if (settings['plex_protocol'] == 'https' and settings['plex_port'] == '443') or (settings['plex_protocol'] == 'http' and settings['plex_port'] == '80'):
            plex_url = f"{settings['plex_protocol']}://{settings['plex_url']}"
        else:
            plex_url = f"{settings['plex_protocol']}://{settings['plex_url']}:{settings['plex_port']}"
        session = requests.Session()
        session.verify = False
        return PlexServer(plex_url, settings['plex_token'], session=session)
    except Exception as e:
        log(f'Failed to connect to Plex server: {e}', conn=conn)
        return None

def get_or_create_barcode_local(rating_key, media_type, conn):
    row = conn.execute('SELECT barcode FROM barcodes WHERE rating_key = ?', (rating_key,)).fetchone()
    if row: return
    new_code = ''.join(str(random.randint(0, 9)) for _ in range(12))
    try:
        conn.execute('INSERT INTO barcodes (rating_key, barcode, media_type) VALUES (?, ?, ?)', (rating_key, new_code, media_type))
    except sqlite3.IntegrityError:
        log(f'Barcode collision for rating key {rating_key}, will retry on next sync.', conn=conn)

def main():
    db_connection = get_db()
    try:
        log('Starting Plex library sync...', conn=db_connection)
        plex = get_plex_server(conn=db_connection)
        if not plex:
            log('Sync failed: Could not connect to Plex server.', conn=db_connection)
            return
        all_media = plex.library.all()
        log(f'Found {len(all_media)} items in Plex library.', conn=db_connection)
        media_items_to_db = []
        for item in all_media:
            if item.type in ('movie', 'show'):
                directors = json.dumps([d.tag for d in getattr(item, 'directors', [])])
                actors = json.dumps([a.tag for a in getattr(item, 'actors', [])])
                genres = json.dumps([g.tag for g in getattr(item, 'genres', [])])
                media_items_to_db.append((
                    str(item.ratingKey),
                    item.title,
                    getattr(item, 'year', None),
                    item.type,
                    getattr(item, 'contentRating', 'Unrated') or 'Unrated',
                    item.thumb,
                    directors,
                    actors,
                    genres
                ))
        log('Clearing old media items table...', conn=db_connection)
        db_connection.execute('DELETE FROM media_items')
        log(f'Inserting {len(media_items_to_db)} new media items into database...', conn=db_connection)
        db_connection.executemany('''
            INSERT OR REPLACE INTO media_items (rating_key, title, year, media_type, contentRating, thumb, directors_json, actors_json, genres_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', media_items_to_db)
        db_connection.commit()
        log('Verifying and creating barcodes for all media items...', conn=db_connection)
        media_to_barcode = db_connection.execute('SELECT rating_key, media_type FROM media_items').fetchall()
        count = 0
        for item in media_to_barcode:
            get_or_create_barcode_local(item['rating_key'], item['media_type'], db_connection)
            count += 1
        db_connection.commit()
        log(f'Verified and created barcodes for {count} items.', conn=db_connection)
        log('Plex library sync complete.', conn=db_connection)
    except Exception as e:
        log(f'An error occurred during sync: {e}', conn=db_connection)
    finally:
        db_connection.close()

if __name__ == '__main__':
    main()



