# Plex Barcode Remote 🚀
![Python](https://img.shields.io/badge/Python-3.9%2B-blue?logo=python) ![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi-orange?logo=raspberrypi) ![License](https://img.shields.io/badge/License-Proprietary-red)

> Turn your physical movie collection into a real-life remote control for your Plex server.

This project bridges the gap between your physical media library and your digital Plex server. By using a Raspberry Pi and a simple USB barcode scanner, you can pick up any DVD, Blu-ray, or 4K UHD case, scan its barcode, and have the movie or TV show instantly start playing on any Plex client in your home.

## Dashboard Preview
The entire system is managed through a clean, simple web dashboard that runs on the Raspberry Pi and is accessible from any device on your network.



---
## Core Features ✨

-   **🖥️ Web-Based Dashboard:** A full-featured UI to manage your library, clients, and settings from any browser.
-   **🔒 Secure Login:** The dashboard is protected by a username and password, with user management on the setup page.
-   **- Barcode Scanning:** Supports both common USB HID (keyboard emulation) and Serial barcode scanners.
-   **📺 Multi-Client Control:** Play media directly to any standard Plex client or Google Chromecast on your network.
-   **📄 PDF Card Generation:** Create printable, card-sized posters with barcodes for your entire digital library, optimized for low-memory devices.
-   **⚡ High-Performance Caching:** The dashboard is powered by a local database cache of your Plex library, making searching and browsing nearly instantaneous.
-   **🔍 Media Discovery:**
    -   Click on an actor's or director's name to see all other content they're involved with in your Plex library.
    -   If you scan a barcode for media you *don't* own, the system automatically looks it up online using the TMDB API and logs the title.
-   **💡 Modern UI:**
    -   **Dark Mode:** A theme toggle to switch between light and dark modes, with your preference saved.
    -   **Live Status:** A real-time status panel provides instant feedback on barcode scans and playback commands.

---
## Requirements

#### Hardware
* A **Raspberry Pi** (Model 3B or newer recommended).
* A reliable 16GB or larger **SD Card**.
* A proper **Power Supply** for your Raspberry Pi model.
* A **USB Barcode Scanner**.

#### Software
* A fresh installation of **Raspberry Pi OS**.
* A running and configured **Plex Media Server** on the same local network.

---
## Installation (Docker) 🐳

The application now runs entirely within Docker containers for easy deployment on Raspberry Pi.

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/sean-gordon/plex-barcode-remote.git
    cd plex-barcode-remote
    ```

2.  **Start the containers**:
    ```bash
    docker-compose up -d
    ```
    This will start the web dashboard (port 5000), the barcode listener, and a Redis instance for live updates.

---
## Setup & Configuration

1.  **Access the Dashboard**: Open `http://<PI_IP>:5000` in your browser.
2.  **Initial Login**: Use default credentials (**Admin** / **Admin**).
3.  **Plex OAuth**: On the Setup page, click **"Login with Plex"**. You will be redirected to link your account.
4.  **Server Selection**: Once authenticated, select your Plex server from the dropdown. 
    > [!TIP]
    > If running inside Docker, try selecting a **Relay** or **Remote** connection if the local IP is unreachable.
5.  **Configure Hardware**: Select your USB scanner or NFC reader device and save settings.

---
## Development

-   **Live Updates**: the project directory is mounted as a volume in the container, so changes to `.py` or `.html` files apply immediately.
-   **Rebuilding**:
    ```bash
    docker-compose up -d --build
    ```

## License

Copyright (c) 2025 Sean Gordon. All Rights Reserved.
Proprietary software. No license is granted to use, copy, modify, or distribute without explicit permission.

