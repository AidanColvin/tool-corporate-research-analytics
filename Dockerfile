FROM python:3.11-slim

WORKDIR /app

# Install dependencies first (layer-cached if requirements.txt unchanged)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy only production source — tests/, Makefile, .env excluded via .dockerignore
COPY src/ ./src/

# Output directory for --output flag via volume mount
RUN mkdir -p output

ENTRYPOINT ["python", "-m", "src.main"]
