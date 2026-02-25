# Project: Plex Barcode Remote (Dockerized)

## Overview
**Plex Barcode Remote** is a system designed to run on a Raspberry Pi via Docker. It enables users to trigger Plex media playback on various clients (Plex clients, Chromecast) by scanning physical barcodes or NFC tags associated with media items.

## Architecture
The application runs as two main Docker containers:

*   **`web`**: A Flask-based web dashboard for library management, running on port 5000. It also handles background tasks like library syncing and PDF generation.
*   **`listener`**: A background service that listens for input from USB Barcode Scanners or NFC Readers (acting as keyboards) via `/dev/input` or Serial.

Data is persisted in a Docker volume `config_data`.

## Tech Stack
*   **Language:** Python 3.9
*   **Containerization:** Docker, Docker Compose
*   **Web Framework:** Flask
*   **Database:** SQLite (persisted in volume)
*   **Input:** `evdev` (HID/NFC), `pyserial`

## Usage (Raspberry Pi)

1.  **Prerequisites:**
    *   Docker and Docker Compose installed.
    *   USB Scanner or NFC Reader connected.

2.  **Start the Application:**
    ```bash
    docker-compose up -d
    ```

3.  **Access Dashboard:**
    Open `http://<PI_IP>:5000`

4.  **Hardware Config:**
    *   The `listener` service attempts to access `/dev/input` and `/dev/ttyACM0`. 
    *   If your device path differs, update `docker-compose.yml`.
    *   **NFC Support:** The listener accepts alphanumeric input, suitable for NFC tags that type their ID as text.

## Development
*   **Source Files:** Python files are now standalone (extracted from the legacy `install.sh`).
*   **Modifying:** Edit the `.py` files or `templates/`, then rebuild:
    ```bash
    docker-compose build && docker-compose up -d
    ```
