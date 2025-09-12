-- создаём БД mydb строго с ICU ru-RU + UTF8
CREATE DATABASE mydb
  WITH ENCODING 'UTF8'
       LOCALE_PROVIDER icu
       ICU_LOCALE 'ru-RU'
       TEMPLATE template0;

-- быстрая проверка (увидишь в логах старта контейнера)
SELECT datname, datcollate, datctype, datlocprovider
FROM pg_database WHERE datname='mydb';
