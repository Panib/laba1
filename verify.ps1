<#
verify.ps1 — полная проверка Задания №1 «с нуля» на Windows

Опции:
  -Reinit          Полная реинициализация БД (удалит db/data)
  -Gui             Ввод логина/пароля через GUI (Tkinter)
  -InjectionTest   Демонстрация защиты от «подмешивания» лишних опций в config.json

Примеры:
  .\verify.ps1
  .\verify.ps1 -Reinit
  .\verify.ps1 -Gui
  .\verify.ps1 -InjectionTest
#>

param(
  [switch]$Reinit,
  [switch]$Gui,
  [switch]$InjectionTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # гасим лишние прогрессы PowerShell
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Section($t){ Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Pass($m){ Write-Host "PASS: $m" -ForegroundColor Green }
function Info($m){ Write-Host "INFO: $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "FAIL: $m" -ForegroundColor Red }

function ExecOk($cmd, $args) {
  # Запускает процесс и возвращает [bool success, string stdout+stderr]
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $cmd
  $psi.Arguments = $args
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  $code = $p.ExitCode
  return ,@($code -eq 0, ($out + $err))
}

# 0) Предварительные проверки
Section "Предварительные проверки"
try {
  docker version | Out-Null
  Pass "Docker доступен"
} catch {
  Fail "Docker не запущен. Открой Docker Desktop и повтори."
  exit 1
}

# 1) Поднять PostgreSQL 17 (docker-compose, порты как есть)
Section "Поднятие PostgreSQL 17 (docker-compose)"
Set-Location $repoRoot

if ($Reinit) {
  docker compose down --remove-orphans | Out-Null
  if (Test-Path "$repoRoot\db\data") { Remove-Item -Recurse -Force "$repoRoot\db\data" }
  Pass "Реинициализация включена (-Reinit): папка db\data очищена"
}

docker compose up -d | Out-Null
Pass "Контейнер pg17 запущен"

Info "Состояние контейнера:"
docker ps --filter "name=pg17"

# 2) Ожидание готовности сервера
Section "Ожидание готовности сервера"
$ready = $false
# ждём до ~90 сек: сначала pg_isready, затем реальный SELECT 1
for ($i=1; $i -le 180; $i++) {
  $ok1,$_ = ExecOk "docker" 'exec pg17 bash -lc "pg_isready -U postgres -d postgres -q"'
  if ($ok1) {
    $ok2,$_ = ExecOk "docker" 'exec pg17 bash -lc "psql -U postgres -d postgres -qAt -c ''SELECT 1;'' >/dev/null 2>&1"'
    if ($ok2) { $ready = $true; break }
  }
  Start-Sleep -Milliseconds 500
}
if (-not $ready) {
  docker logs --tail 200 pg17
  Fail "Сервер так и не стал доступен (таймаут ~90 сек)"
  exit 1
} else {
  Pass "Сервер готов принимать подключения"
}

# 3) Доказательства (внутри контейнера)
Section "Доказательства (внутри контейнера)"

# Версия
$ok,$verOut = ExecOk "docker" 'exec pg17 bash -lc "psql -U postgres -d mydb -qAt -c ''SELECT version();''"'
if (-not $ok) { Fail "SELECT version() не выполнился:`n$verOut"; exit 1 }
$ver = $verOut.Trim()
if ($ver -match "^PostgreSQL\s+17") {
  Pass "Версия сервера: $ver"
} else {
  Fail "Ожидалась 17.x, получено: $ver"
  exit 1
}

# ICU / локаль (важно увидеть 'i' и ru-RU в actual_version)
$ok,$locOut = ExecOk "docker" 'exec pg17 bash -lc "psql -U postgres -d mydb -qAt -c ''SELECT datname,datcollate,datctype,datlocprovider,pg_database_collation_actual_version(oid) FROM pg_database WHERE datname=''\'\''mydb''\'\'';''"'
if (-not $ok) { Fail "Не удалось получить локаль БД:`n$locOut"; exit 1 }
$loc = $locOut.Trim()
if ($loc -match "\|i\|") {
  Pass "Локаль ICU активна: $loc"
} else {
  Fail "ICU не активен (datlocprovider!='i'): $loc"
}

# SCRAM в pg_hba.conf
$ok,$hbaOut = ExecOk "docker" 'exec pg17 bash -lc "grep -n ''scram-sha-256'' /var/lib/postgresql/data/pg_hba.conf | wc -l"'
if (-not $ok) { Fail "Не удалось проверить pg_hba.conf:`n$hbaOut"; exit 1 }
[int]$hbaCount = 0; [void][int]::TryParse($hbaOut.Trim(), [ref]$hbaCount)
if ($hbaCount -ge 1) { Pass "pg_hba.conf содержит 'scram-sha-256' ($hbaCount совп.)" } else { Fail "В pg_hba.conf не найден 'scram-sha-256'"; exit 1 }

# Вход под app_user
$ok,$whoOut = ExecOk "docker" 'exec pg17 bash -lc "psql -U app_user -d mydb -qAt -c ''SELECT current_user||''\''|''\''||current_database();''"'
if (-not $ok) { Fail "Не удалось войти под app_user:`n$whoOut"; exit 1 }
$who = $whoOut.Trim()
if ($who -eq "app_user|mydb") { Pass "Вход под app_user в mydb: $who" } else { Fail "Ожидалось app_user|mydb, получено: $who"; exit 1 }

# 4) Подготовка клиент-приложения (конфиг рядом)
Section "Подготовка клиент-приложения (config рядом)"
Set-Location "$repoRoot\app"

if (-not (Test-Path ".\config.json")) {
  if (Test-Path ".\config.example.json") {
    Copy-Item .\config.example.json .\config.json -Force
    # гарантируем UTF-8 без BOM
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText("$PWD\config.json", (Get-Content .\config.json -Raw), $utf8NoBom)
    Pass "Создан app\config.json из app\config.example.json"
  } else {
    Fail "Нет app\config.json и app\config.example.json"; exit 1
  }
}

if (-not (Test-Path ".venv")) { py -3 -m venv .venv; Pass "Создано виртуальное окружение .venv" }
. .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt | Out-Null
Pass "Зависимости установлены"

# 5) Ввод логина/пароля (по заданию)
Section "Ввод учётных данных (по заданию)"
if ($Gui) {
  Info "Режим GUI: окно ввода логина/пароля покажет приложение"
  $credsArgs = @("--gui")
} else {
  $defUser = "app_user"
  $defPass = "password"
  $u = Read-Host "Введите логин БД [`$def: $defUser`]" 
  if ([string]::IsNullOrWhiteSpace($u)) { $u = $defUser }
  $pSecure = Read-Host "Введите пароль БД [`$def: $defPass`]" -AsSecureString
  if (!$pSecure) { $pPlain = $defPass } else { $pPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pSecure)) }
  $credsArgs = @("--user", $u, "--password", $pPlain)
  Info "Будет выполнен запуск приложения с введёнными данными (логин: $u)"
}

# 6) (Опционально) Тест безопасной склейки
$backupPath = "$repoRoot\app\config.json.bak"
if ($InjectionTest) {
  Section "Тест безопасной склейки (InjectionTest)"
  Copy-Item ".\config.json" $backupPath -Force
  $cfg = Get-Content ".\config.json" -Raw
  if ($cfg -notmatch '"options"') {
    $cfg = $cfg.TrimEnd("`r","`n"," ","`t")
    if ($cfg[-1] -eq "}") {
      $cfg = $cfg.Substring(0, $cfg.Length-1) + ",`n  `"options`": `"-c search_path=evil`"`n}"
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText("$PWD\config.json", $cfg, $utf8NoBom)
    Info "В config.json добавлен лишний ключ options — приложение должно его проигнорировать (whitelist)."
  } else {
    Info "В config.json уже есть поле options — пропускаем подмешивание"
  }
}

# 7) Запуск приложения (SELECT version())
Section "Запуск приложения (SELECT version())"
$appOutOk = $false
try {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = "py"
  $psi.Arguments = ("main.py " + ($credsArgs -join " "))
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $appOut = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -eq 0 -and ($appOut -match "PostgreSQL version")) {
    $appOutOk = $true
  }
} catch {
  $appOutOk = $false
}

if ($appOutOk) {
  Pass "Приложение успешно подключилось и выполнило SELECT version()"
  Write-Host $appOut
} else {
  Fail "Приложение не смогло выполнить SELECT version(). Вывод ниже:"
  Write-Host $appOut
  exit 1
}

# 8) Итог
Section "ИТОГО"
Write-Host "• Сервер        : $ver"
Write-Host "• Локаль (ICU)  : $loc"
Write-Host "• pg_hba.conf   : scram-sha-256 ($hbaCount совп.)"
Write-Host "• Проверка логина: $who"
Pass "Задание №1 — ВЫПОЛНЕНО. Все пункты подтверждены."

# cleanup после InjectionTest
if ($InjectionTest -and (Test-Path $backupPath)) {
  Move-Item $backupPath ".\config.json" -Force
  Info "config.json восстановлён после InjectionTest"
}
