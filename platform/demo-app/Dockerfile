FROM python:3.11-alpine

WORKDIR /app

RUN pip install --no-cache-dir flask==3.0.3

COPY app.py .

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O- http://localhost:8080/health || exit 1

CMD ["python", "app.py"]
