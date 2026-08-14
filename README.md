# QTerm — MVP-каркас

Терминал + SFTP-проводник для мака. Рабочее название, переименовывается.
НЕ КОМПИЛИРОВАЛСЯ — здесь нет macOS. Ожидаемо потребуется 3–5 правок сигнатур
после первого `swift build` (все места помечены комментариями в коде).

## Раскладка

```
рядом в одной папке:
  SessionVaultKit/     <- пакет из прошлого шага (вейлт, SE, Keychain)
  QTerm/               <- этот пакет
```

## Сборка

```
cd QTerm
swift build            # первая итерация: чинить сигнатуры Citadel по ошибкам
./make-app.sh          # бандл + подпись (серт сделать по образцу QSwitcher make-cert.sh)
```

Бандл обязателен (не raw-бинарь): Touch ID/Keychain привязываются к подписи
бандла — те же грабли, что были с TCC в QSwitcher.

## Архитектура

- `QTermApp.swift` — AppState: сессии из вейлта, коннекты по id
- `ContentView.swift` — сайдбар сессий + HSplitView(терминал | проводник)
- `SSHConnection.swift` — Citadel: одно соединение, shell(PTY) + SFTP
- `TerminalHostView.swift` — SwiftTerm ↔ SSHConnection (feed/send/resize)
- `SFTPBrowserView.swift` — листинг, up/down/rm/mkdir/rename, правка через
  временный файл с vnode-watcher и автозаливкой при сохранении
- `EditSessionView.swift` — форма сессии; секреты → Keychain, не в вейлт

## Известные точки риска (проверить первыми)

1. **Сигнатуры Citadel** — `SSHClient.connect(...)` vs `SSHClientSettings`,
   тип элементов `ttyOutput` (ByteBuffer или enum), наличие
   `TTYStdinWriter.changeSize`. Всё в `SSHConnection.swift`, помечено.
   Если changeSize нет в затянутой версии — резайз через переоткрытие
   shell-канала, либо форк (есть прецедент: heyfinal/Citadel с расширенным PTY API).
2. **Распаковка листинга SFTP** — структура `SFTPMessage.Name.components`
   в `SFTPBrowser.list`. Определение каталога сейчас по `longname` ("d" в
   начале) — грубо, но работает с OpenSSH; правильнее по permissions-битам
   из attributes.
3. **SwiftTerm delegate** — набор методов протокола TerminalViewDelegate
   зависит от версии; недостающие добавить пустыми, лишние убрать.
4. **hostKeyValidator: .acceptAnything()** — ВРЕМЕННО. До использования на
   реальных серверах добавить TOFU: отпечаток в `Session.extra["hostkey"]`,
   при несовпадении — алерт. Для твоих серверов это не формальность.
5. Ключи ed25519 only в MVP (`makeAuthMethod`). RSA-ветка — одна строка,
   добавить когда попадётся первый RSA-хост (Keenetic с ssh-rsa — как раз
   такой случай, см. `-oHostKeyAlgorithms=+ssh-rsa`).

## Что сознательно отложено

- вкладки/несколько соединений на сессию
- jump-hosts, agent, port forwarding
- темы терминала, поиск, скроллбек-настройки
- синк (WebDAV) и автообновления — после рабочего терминала
- иконка

## Порядок доводки

1. `swift build` → починить сигнатуры (пункты 1–3)
2. Запуск из бандла → создание вейлта (Touch ID) → добавить сессию → коннект
3. Проверить: ввод/вывод в терминале, resize, cyrillic, tmux/vim/mc
4. Проводник: листинг, скачивание, заливка, правка с автозаливкой
5. TOFU host keys (пункт 4) — до перевода реальных серверов
