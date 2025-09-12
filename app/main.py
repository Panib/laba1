import json
import getpass
import sys
import argparse
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

try:
    import tomllib  # Python 3.11+
except ImportError:
    tomllib = None

import psycopg

# Для GUI
import tkinter as tk
from tkinter import simpledialog, messagebox

ALLOWED_KEYS = {
    "host": str,
    "port": int,
    "dbname": str,
    "connect_timeout": int,
    "sslmode": str,
}

def load_config(path: Path) -> dict:
    text = path.read_text(encoding="utf-8-sig")  # поддержка BOM
    if path.suffix.lower() == ".json":
        raw = json.loads(text)
    elif path.suffix.lower() in (".yaml", ".yml"):
        if yaml is None:
            raise RuntimeError("Установите pyyaml для YAML конфигов")
        raw = yaml.safe_load(text)
    elif path.suffix.lower() == ".toml":
        if tomllib is None:
            raise RuntimeError("Python 3.11+ нужен для TOML (tomllib)")
        raw = tomllib.loads(text)
    else:
        raise ValueError("Файл конфигурации должен быть .json, .yaml/.yml или .toml")

    if not isinstance(raw, dict):
        raise ValueError("Конфиг должен быть объектом")

    cfg = {}
    for k, v in raw.items():
        if k in ALLOWED_KEYS and isinstance(v, ALLOWED_KEYS[k]):
            cfg[k] = v

    for required in ("host", "port", "dbname"):
        if required not in cfg:
            raise ValueError(f"Нет обязательного ключа: {required}")

    return cfg

def prompt_credentials_console():
    user = input("Введите логин БД: ").strip()
    password = getpass.getpass("Введите пароль БД: ")
    if not user or any(c in user for c in " \t\r\n;='\"\\"):
        print("Неверный логин (запрещены пробелы/кавычки/слэши).", file=sys.stderr)
        sys.exit(1)
    return user, password

def prompt_credentials_gui():
    root = tk.Tk()
    root.withdraw()  # скрыть основное окно
    user = simpledialog.askstring("PostgreSQL", "Введите логин БД:")
    password = simpledialog.askstring("PostgreSQL", "Введите пароль БД:", show="*")
    if not user or any(c in user for c in " \t\r\n;='\"\\"):
        messagebox.showerror("Ошибка", "Неверный логин (запрещены пробелы/кавычки/слэши).")
        sys.exit(1)
    return user, password

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Проверка запуска без подключения к БД")
    parser.add_argument("--gui", action="store_true", help="Ввод логина/пароля через GUI")
    parser.add_argument("--user", type=str, help="Логин БД (небезопасно хранить в истории, используйте с осторожностью)")
    parser.add_argument("--password", type=str, help="Пароль БД (небезопасно хранить в истории, используйте с осторожностью)")
    args = parser.parse_args()

    if args.dry_run:
        print("Dry-run OK: приложение запускается.")
        return

    base = Path(__file__).parent
    config_path = None
    for cand in (base/"config.json", base/"config.yaml", base/"config.yml", base/"config.toml"):
        if cand.exists():
            config_path = cand
            break
    if not config_path:
        print("Положите рядом config.json, config.yaml или config.toml (см. примеры)", file=sys.stderr)
        sys.exit(1)

    cfg = load_config(config_path)

    if args.user is not None and args.password is not None:
        user, password = args.user, args.password
    elif args.gui:
        user, password = prompt_credentials_gui()
    else:
        user, password = prompt_credentials_console()

    conn_kwargs = dict(cfg)
    conn_kwargs["user"] = user
    conn_kwargs["password"] = password

    with psycopg.connect(**conn_kwargs) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT version();")
            print("PostgreSQL version:\n", cur.fetchone()[0])


if __name__ == "__main__":
    main()
