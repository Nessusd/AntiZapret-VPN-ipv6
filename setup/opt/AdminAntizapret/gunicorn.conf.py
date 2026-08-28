import os
import logging


logger = logging.getLogger(__name__)

workers = int(os.getenv('GUNICORN_WORKERS', 1))
app_port = os.getenv("APP_PORT", "5050")
bind = [f'{os.getenv("BIND", "0.0.0.0")}:{app_port}']
bind_ipv6 = (os.getenv("BIND_IPV6") or "").strip()
if bind_ipv6:
    bind.append(f'[{bind_ipv6}]:{app_port}')
worker_class = "gthread"
threads = 8
timeout = 300
graceful_timeout = 300
keepalive = 2
max_requests = int(os.getenv('GUNICORN_MAX_REQUESTS', 1200))
max_requests_jitter = int(os.getenv('GUNICORN_MAX_REQUESTS_JITTER', 120))
errorlog = '-'
accesslog = '-'

certfile = None
keyfile = None
if os.getenv('USE_HTTPS', 'false').lower() == 'true':
    configured_certfile = os.getenv('SSL_CERT')
    configured_keyfile = os.getenv('SSL_KEY')
    if configured_certfile and configured_keyfile:
        certfile = configured_certfile
        keyfile = configured_keyfile
    else:
        logger.warning("HTTPS включен, но сертификаты не заданы. Используется HTTP.")
