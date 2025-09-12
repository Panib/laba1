-- создаём обычного пользователя, если нет
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user LOGIN PASSWORD 'password';
  END IF;
END$$;

-- подключаемся к mydb (psql-метакоманда)
\connect mydb

-- права на БД и схему public
GRANT CONNECT ON DATABASE mydb TO app_user;
GRANT USAGE   ON SCHEMA public TO app_user;

-- проверки
SELECT current_user, current_database(), version();
