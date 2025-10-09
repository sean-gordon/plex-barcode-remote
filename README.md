# Plex Barcode Remote 🚀

> Turn your physical movie collection into a real-life remote control for your Plex server.

This project bridges the gap between your physical media library and your digital Plex server. By using a Raspberry Pi and a simple USB barcode scanner, you can pick up any DVD or Blu-ray case, scan its barcode, and have the movie or TV show instantly start playing on any Plex client in your home.



## At a Glance

The entire system is managed through a clean, simple web dashboard that runs on the Raspberry Pi and is accessible from any device on your network. It features a responsive design and both light and dark modes.



## Core Features ✨

-   **🎬 Instant Playback:** The core feature. Scan a barcode, and your media plays. It intelligently finds the next unwatched episode for TV shows.
-   **🖥️ Web-Based Dashboard:** Manage your media, clients, and settings from a user-friendly web interface.
-   **- Barcode Scanning:** Supports both common USB HID (keyboard emulation) and Serial barcode scanners.
-   **📺 Multi-Client Control:** Play media directly to any standard Plex client (like Android TV, Apple TV, desktop apps) or any Google Chromecast.
-   **📄 PDF Card Generation:** Create printable, Pokémon-card sized posters with their unique barcode for your physical media collection, automatically grouped by age rating.
-   **🔍 Media Discovery:**
    -   Click on an actor's or director's name to see all other content they're involved with in your Plex library.
    -   If you scan a barcode for a movie you *don't* own, the system will look it up online (via TMDB) and log what it was.
-   **💡 Modern UI:**
    -   **Dark Mode:** A theme toggle to switch between light and dark modes, with your preference saved.
    -   **Live Status:** A real-time status panel shows you what's happening as you scan barcodes.

## Requirements

#### Hardware
* A Raspberry Pi (Model 3B or newer recommended).
* A reliable 16GB or larger SD Card.
* A proper power supply for your Raspberry Pi model.
* A USB barcode scanner (configured for HID or Serial mode).

#### Software
* Raspberry Pi OS (or another Debian-based Linux distribution).
* A running and configured Plex Media Server on your network.

## Installation

The entire application is installed and configured using a single script.

1.  Clone this repository to your Raspberry Pi's home directory:
    ```bash
    git clone https://github.com/sean-gordon/plex-barcode-remote.git
    ```
2.  Navigate into the new directory:
    ```bash
    cd plex-barcode-remote
    ```
3.  Make the installer executable and run it:
    ```bash
    chmod +x install.sh
    bash ./install.sh
    ```
4.  The script will install all dependencies, set up the database, and start the required background services.

## Setup & Configuration

After the installation is complete, there are a few one-time setup steps.

#### Step 1: First Run & Server Setup
Access the web dashboard by finding your Pi's IP address (run `hostname -I` in the terminal) and navigating to `http://<YOUR_PI_IP_ADDRESS>:5000` in a web browser. You'll be taken to the setup page.



-   **Plex Details:** Enter your Plex server's IP address, port (usually 32400), and your [Plex Authentication Token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/).
-   **TMDB API Key (Optional):** To enable the "Missing Media Lookup" feature, get a free API key from [The Movie Database](https://www.themoviedb.org/settings/api) and paste it here.

#### Step 2: Configure Your Player
On the main dashboard, find the "Playback Target" panel. Click "Refresh Clients" to find all available Plex clients on your network. Select your primary player from the dropdown and click "Set".



#### Step 3: Configure Your Barcode Scanner
In the "Scanner Settings" panel, choose your scanner's mode (HID Keyboard is most common) and select the correct device from the dropdown, then click "Save & Restart Listener".



## Usage Guide

-   **Playing Media:** Simply scan the barcode on a DVD or Blu-ray case. The live status panel will update, and the media will begin playing on your selected client.

-   **Generating PDFs:** In the "System" panel, click "Start PDF Generation". The process will run in the background (this can take a long time for the first run). When it's finished, a "Download PDFs" link will appear.

-   **Discovering Media:** Click on an actor's or director's name in the main table to see all other content they are involved with in your library.

## Maintenance

#### Checking Service Status
You can check the status of the two background services (the web server and the scanner listener) with these commands:
```bash
sudo systemctl status plex-barcode-web.service
sudo systemctl status plex-barcode-listener.service
```

### License
Copyright (c) 2025 Sean Gordon. All Rights Reserved.

This project is proprietary. You may view the source code for educational purposes, but you are not granted any license to use, copy, modify, or distribute this software without explicit written permission from the copyright holder.
