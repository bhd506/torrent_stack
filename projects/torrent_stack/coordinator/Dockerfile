FROM python:3.13-alpine

WORKDIR /app
COPY coordinator.py /app/coordinator.py

ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-u", "/app/coordinator.py"]
