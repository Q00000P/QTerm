# QTerm Windows

Третья платформа QTerm — SSH-клиент со сквозным шифрованным синком вейлта
(macOS · Android · Windows): ноды, ключи, сниппеты, журнал команд и доверие
хостам едины на всех устройствах.

**Возможности:** терминал (xterm.js в WebView2, N вкладок), SFTP + exec-фолбэк
для dropbear/BusyBox, редактор вкладками + внешний редактор с авто-заливкой,
мониторинг серверов, подсказки команд у курсора, WYSIWYG-броадкаст «во все
ноды», авто-реконнект с бэкоффом, PPK2/PPK3-конвертер (Argon2id, MAC-проверка),
ssh-agent/Pageant, Windows Hello, синк через Google Drive или WebDAV (QTS1,
Argon2id + AES-GCM).

**Ноды 3x-ui и AWG** (окно «Ноды 3x-ui»): единая подписка через узлы 3x-ui v3 —
мониторинг, клиенты главной с рассылкой на узлы, подключение и ревизия нод,
единые имена (`PC` — VLESS, `PC-HYS` — Hysteria, `PC-SYNC` — оба); клиенты
AWG (awg-panel и старая amnezia-wg-easy) — конфиги, QR, вкл/выкл. Новая нода
или переустановка — выделить итог установщика в терминале и нажать
`Ctrl+Shift+A`: вход по паролю, выпуск API-токена, перепривязка узла на главной.

Окна работают на нескольких мониторах с разным масштабом (Per-Monitor V2):
влезают в экран, открываются на мониторе своего окна, помнят размер и место.

**Стек:** .NET 8 · WPF · SSH.NET · WebView2 + xterm.js · DPAPI-вейлт.

## Сборка

```powershell
dotnet run          # дев-запуск (заодно собирает Editor\QEditor)
.\publish.cmd       # релиз: publish\QTerm.exe + publish\QEditor.exe (+ портативный zip)
```

Секреты в исходниках не хранятся. Google client secret (вход в Google Drive
для синка) подставляется при сборке: файл `secrets.local.props` рядом с
`QTermWin.csproj` (в `.gitignore`)

```xml
<Project>
  <PropertyGroup>
    <QTermGoogleClientSecret>…</QTermGoogleClientSecret>
  </PropertyGroup>
</Project>
```

или переменная окружения `QTERM_GOOGLE_CLIENT_SECRET`. Без него всё собирается,
не работает только вход в Google Drive (WebDAV работает).

**CI:** каждый пуш в `main`, задевающий `windows/`, собирает релиз на `windows-latest`
(`.github/workflows/windows.yml` в корне репозитория) и выкладывает
`QTerm-win-vX.Y.Z.zip` в Releases под тегом `win-vX.Y.Z`;
секрет — `QTERM_GOOGLE_CLIENT_SECRET` в Settings → Secrets → Actions.

Редактор — отдельное приложение **QEditor.exe** (`Editor\`, своя иконка и кнопка
в таскбаре, как QTermEditor.app на маке). Файлы нод открываются из QTerm и
сохраняются обратно через его SSH по именованному каналу; локальные документы
(скрапбук) QEditor пишет на диск сам.

QEditor — уровня MobaTextEditor: AvalonEdit (нумерация строк, подсветка 14 языков
в тёмной палитре, прямоугольное выделение Alt+мышь), строка меню Файл / Правка /
Поиск / Вид / Формат / Кодировка / Синтаксис / Инструменты, тулбар, поиск и замена
с регулярками, закладки (Ctrl+F2 / F2), кодировки (UTF-8/BOM, 1251, KOI8-R, CP866,
UTF-16), концы строк LF/CRLF, операции над строками, Base64/URL/JSON/хеши,
сравнение вкладок (DiffPlex), печать. Файлы нод передаются сырыми байтами —
кодировку и концы строк определяет редактор.

Релиз — папка `publish` целиком: Assets обязаны лежать рядом с exe
(WebView2 маппит их в virtual host).

Мак-версия — корень этого репозитория; Android — QTermAndroid.
