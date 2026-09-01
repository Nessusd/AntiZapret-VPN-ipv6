# Blueprint отделяет сессию Mini App от обычных маршрутов панели.
from flask import Blueprint

bp = Blueprint(
    "tg_mini",
    __name__,
    template_folder="templates",
    static_folder="static",
    static_url_path="/tg-mini/assets",
)
