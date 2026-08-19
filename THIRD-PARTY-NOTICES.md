# Сторонние компоненты

QTerm использует следующие открытые компоненты. Их лицензии сохранены в
соответствующих репозиториях; форки содержат оригинальные копирайты.

| Компонент | Лицензия | Использование |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) (форк [Q00000P/Citadel](https://github.com/Q00000P/Citadel)) | MIT | SSH/SFTP. Изменения форка: подпись rsa-sha2-256 вместо ssh-rsa (SHA-1), транспорт AES128-CTR |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | эмулятор терминала |
| [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) 0.13.2 | MIT | встроенный редактор (ставится setup-deps.sh с патчами для CLI-сборки: локальный CodeEditSymbols, без SwiftLint) |
| [CodeEditSymbols](https://github.com/CodeEditApp/CodeEditSymbols) 0.2.3 | MIT | зависимость редактора (патч: системные SF Symbols вместо xcassets — swift build не обрабатывает xcassets) |
| [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) 0.11.1, [CodeEditLanguages](https://github.com/CodeEditApp/CodeEditLanguages) 0.1.20, [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter), tree-sitter и его грамматики | MIT / MIT-совместимые | подсветка синтаксиса |
| [Argon2Swift](https://github.com/tmthecoder/Argon2Swift) (форк [Q00000P/Argon2Swift](https://github.com/Q00000P/Argon2Swift)) | MIT | Argon2 для конвертера PPK3. Изменения форка: исправлены exclude-пути в Package.swift (сборка на arm64) |
| [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) (внутри Argon2Swift) | CC0 / Apache-2.0 | референс-реализация Argon2 |
| swift-nio, swift-nio-ssh, swift-crypto, swift-log и пр. Apple-пакеты | Apache-2.0 | транзитивные зависимости |
