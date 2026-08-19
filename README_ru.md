# WANPilot для OpenWrt

![OpenWrt](https://img.shields.io/badge/OpenWrt-LuCI-blue?style=for-the-badge&logo=openwrt)
![Multi-WAN](https://img.shields.io/badge/Mode-Multi--WAN-orange?style=for-the-badge)
![Shell](https://img.shields.io/badge/Language-POSIX_Shell-green?style=for-the-badge&logo=gnu-bash)

[English version](README.md)

WANPilot — лёгкий менеджер uplink-интерфейсов для OpenWrt с нативным виджетом LuCI, проверяемым переключением через метрики и отдельными проверками доступности и задержки Google/Yandex для каждого интерфейса.

WANPilot работает со стандартным сетевым стеком OpenWrt: он не заменяет маршрутизацию, firewall или управление интерфейсами и не требует отдельного multi-WAN фреймворка.

---

## Возможности

- автоматическое обнаружение uplink-интерфейсов в выбранной firewall-зоне;
- ручное добавление интерфейсов вне discovery-зоны;
- определение активного uplink по реальным default route и effective metric;
- понятная обработка интерфейсов с одинаковым приоритетом;
- проверяемое переключение uplink с автоматическим откатом метрик при ошибке;
- независимые проверки Google и Yandex через каждый интерфейс;
- статус `ONLINE`, если доступен хотя бы Google или Yandex;
- стабильное отображение RTT и лёгкая анимация ручной проверки;
- адаптивные карточки на стандартной странице LuCI Overview;
- страницы настройки и текущего состояния в LuCI;
- CLI и API через `rpcd`/`ubus`;
- поддержка версий OpenWrt как с `apk`, так и с `opkg`.

---

## Быстрая установка

Выполните команду от пользователя `root` в терминале OpenWrt:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/WANPilot/main/install.sh)"
```

Если `wget` недоступен, используйте стандартный загрузчик OpenWrt:

```sh
sh -c "$(uclient-fetch -O- https://raw.githubusercontent.com/F5GO/WANPilot/main/install.sh)"
```

Установщик всегда скачивает текущее содержимое ветки `main` репозитория `F5GO/WANPilot`.

> [!CAUTION]
> Установка намеренно выполняется начисто: предыдущая версия WANPilot и `/etc/config/wanpilot` удаляются, после чего устанавливается актуальная версия с настройками по умолчанию. Стандартные пакеты OpenWrt и посторонние секции `pingcheck` сохраняются.

После установки откройте:

- `Status → Overview` — основной виджет;
- `Network → WANPilot → Configuration` — настройки;
- `Network → WANPilot → Runtime Status` — подробное состояние.

---

## Требования

| Компонент | Требование |
|---|---|
| Роутер | OpenWrt с LuCI |
| Доступ | терминал с правами `root` |
| Пакетный менеджер | `apk` или `opkg` |
| Обязательные компоненты | `rpcd`, `luci-base`, `uhttpd` |
| Проверка интернета | `curl`; для фоновой интеграции используется `pingcheck` |

Отсутствующие поддерживаемые пакеты устанавливаются автоматически, если они доступны в подключённых репозиториях OpenWrt.

---

## Как определяется статус uplink

WANPilot разделяет состояние интерфейса и реальную доступность интернета:

- `CONNECTED` — интерфейс поднят и имеет подходящий маршрут;
- `ONLINE` — у интерфейса есть default route и хотя бы одна последняя проверка Google/Yandex успешна;
- `OFFLINE` — обе последние проверки завершились ошибкой либо сам интерфейс недоступен;
- `CHECKING` — завершённых результатов проверки пока нет;
- `STOPPED` — сервис WANPilot остановлен через CLI.

Отображаемая задержка — среднее значение трёх коротких ICMP-проб через выбранный интерфейс. Если ICMP недоступен, WANPilot использует время TCP-подключения без DNS lookup. Предыдущий результат остаётся на экране только во время следующей проверки, а затем заменяется новым RTT или `FAIL`.

`Check interval` задаёт паузу между завершёнными автоматическими циклами. `Check timeout` ограничивает время одного запроса к одной цели.

---

## CLI

Основные команды:

```sh
wanpilot status
wanpilot status --json
wanpilot list --json
wanpilot discover --json
wanpilot switch wan
wanpilot probe wan both
wanpilot probe wan google
wanpilot config get --json
```

Управление сервисом:

```sh
wanpilot stop
wanpilot start
wanpilot restart
```

- `stop` сохраняемо отключает управляемые WANPilot проверки и блокирует новые WANPilot-пробы;
- `start` снова включает их с сохранённой конфигурацией;
- `restart` включает WANPilot, очищает устаревшие результаты, синхронизирует управляемые секции `pingcheck` и перезапускает интеграцию;
- посторонняя конфигурация `pingcheck` не удаляется и не отключается.

Полный список команд доступен через `wanpilot help`.

---

## Настройка

WANPilot хранит настройки в `/etc/config/wanpilot`. Основные параметры также доступны в LuCI:

- firewall-зона обнаружения;
- предпочтительная метрика маршрута;
- включение проверки интернета;
- интервал и timeout проверки;
- ручные интерфейсы, отображаемые имена, видимость и порядок.

История метрик интерфейсов хранится только для безопасного восстановления значений, которыми управлял WANPilot.

---

## Обновление

Повторно запустите команду установки. Установщик загрузит текущее содержимое ветки `main` и выполнит чистую установку:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/WANPilot/main/install.sh)"
```

---

## Удаление

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/WANPilot/main/uninstall.sh)"
```

Альтернативный вариант:

```sh
sh -c "$(uclient-fetch -O- https://raw.githubusercontent.com/F5GO/WANPilot/main/uninstall.sh)"
```

Скрипт удаляет файлы и конфигурацию WANPilot, кэши LuCI и проверок, а также управляемые WANPilot секции `pingcheck`. По возможности восстанавливаются исходные метрики интерфейсов. Общие пакеты OpenWrt не удаляются.

---

## Контакты

Проект развивается при поддержке сообщества **F5GO.ONE**.

- **YouTube:** [F5](https://youtube.com/@F5GO)
- **Сайт:** [F5GO.ONE](https://f5go.one)
- **Telegram:** [F5GO](https://t.me/f5gou)

---

> [!IMPORTANT]
> **Лицензия MIT.** Данное программное обеспечение предоставляется «как есть». Используйте его на свой страх и риск.
