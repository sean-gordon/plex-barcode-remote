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
## Installation

The application is installed using a single script from this repository.

1.  Clone this repository to your Raspberry Pi's home directory:
    ```
    git clone [https://github.com/sean-gordon/plex-barcode-remote.git](https://github.com/sean-gordon/plex-barcode-remote.git)
    ```
2.  Navigate into the new directory:
    ```
    cd plex-barcode-remote
    ```
3.  Make the installer executable and run it:
    ```
    chmod +x install.sh
    bash ./install.sh
    ```
4.  The script will install all dependencies, set up the database, and start the required background services.

---
## Setup & Configuration

After the installation is complete, there are a few one-time setup steps.

#### Step 1: Access the Dashboard
Find your Pi's IP address by running `hostname -I` in the terminal. Then, open a web browser and go to `http://<YOUR_PI_IP_ADDRESS>:5000`.

#### Step 2: Initial Login
You will be greeted by a login screen. The default credentials are:
-   **Username:** `Admin`
-   **Password:** `Admin`

#### Step 3: Initial Configuration (Plex, TMDB, User)
After logging in, you will be automatically directed to the setup page. It is highly recommended to fill out all fields.



-   **Plex Details:** Enter your Plex server's IP address, port (usually 32400), and your [Plex Authentication Token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/).
-   **TMDB API Key (Optional):** To enable the "Missing Media Lookup" feature, get a free API key from [The Movie Database](https://www.themoviedb.org/settings/api) and paste it here.
-   **User Management:** It is **highly recommended** that you change the default username and password on this page.
-   Click **"Save Settings"**.

#### Step 4: Automatic Library Sync
After you save your Plex settings for the first time, the system will automatically begin syncing your Plex library to the local cache. This may take several minutes. The main dashboard will be empty until this first sync is complete. You can monitor the progress in the "Logs" page.

#### Step 5: Configure Playback Target & Scanner
Once the sync is complete and your media appears on the dashboard:
-   **Playback Target:** Select your primary player from the dropdown and click "Set".
-   **Scanner Settings:** Choose your scanner type (HID or Serial), select the correct device, and click "Save & Restart Listener".

---
## Maintenance

#### Checking Service Status
You can check the status of the two background services with these commands:
sudo systemctl status plex-barcode-web.service
sudo systemctl status plex-barcode-listener.service


#### Scheduling Background Syncs & Log Cleanup
Two maintenance scripts are included. It is recommended to schedule them to run automatically using `cron`.

1.  Open the cron editor: `crontab -e`
2.  Add these two lines to the bottom of the file (replacing `seangordon` with your username):
    ```cron
    # Run Plex library sync every 6 hours
    0 */6 * * * /home/seangordon/plex-barcode-remote/venv/bin/python /home/seangordon/plex-barcode-remote/sync_plex_library.py
    
    # Run log cleanup every day at 2:15 AM
    15 2 * * * /home/seangordon/plex-barcode-remote/cleanup_logs.sh
    ```
3.  Save and exit.

## License

Copyright (c) 2025 Sean Gordon. All Rights Reserved.

This project is proprietary. You may view the source code for educational purposes, but you are not granted any license to use, copy, modify, or distribute this software without explicit written permission from the copyright holder.
