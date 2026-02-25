FROM python:3.9-slim

# Install system dependencies
# libevdev-dev for python-evdev
RUN apt-get update && apt-get install -y \
    gcc \
    libevdev-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV FLASK_PORT=5000

# Create config directory
RUN mkdir -p /root/.config/plex_barcode_remote

CMD ["python", "web_dashboard.py"]