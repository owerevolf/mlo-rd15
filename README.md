# MLO на Xiaomi BE3600 2.5G (RD15) в OpenWrt

Включает **Wi-Fi 7 Multi-Link Operation** на роутере Xiaomi BE3600 2.5G (RD15,
SoC IPQ5332, QSDK 12.5) в сборке OpenWrt 25.x.

Проверено: клиент Realme Neo7 подключается по двум линкам одновременно —
**229 Мбит/с на 2,4 ГГц + 1921 Мбит/с на 5 ГГц**.

---

## Что это

На стоковой прошивке MLO работает, в OpenWrt-сборках — нет. Причина в том,
что netifd создаёт Wi-Fi интерфейсы не так, как это делает стоковый скрипт
`qcawificfg80211.sh` из QSDK.

Этот проект повторяет стоковую схему создания MLD и запускает hostapd
с правильными параметрами.

**Прошивку пересобирать не нужно** — всё работает поверх существующей сборки.

---

## Требования

| Что | Значение |
|---|---|
| Роутер | Xiaomi BE3600 2.5G (RD15) |
| Прошивка | OpenWrt 25.x с QSDK-драйверами (`umac.ko`) |
| Вендорский `iw` | `/root/iw_mld` (умеет `mld_addr` и `type __ap`) |
| UCI | секция `wireless.mld0` с `mld_macaddr` |
| Клиент | устройство с поддержкой MLO (Wi-Fi 7 с multi-link) |

### Проверка вендорского iw

```sh
/root/iw_mld phy mld-phy0 interface add test0 type __ap mld_addr 16:67:61:90:98:80
```

Если команда не выдаёт `Usage` — iw подходит. Удалить тест: `/root/iw_mld dev test0 del`.

### UCI-секция

```sh
uci set wireless.mld0=wifi-mld
uci set wireless.mld0.mld_macaddr='16:67:61:90:98:80'
uci set wireless.mld0.link_mac='04:67:61:90:98:83 04:67:61:90:98:82'
uci set wireless.mld0.link_id='1 0'
uci set wireless.mld0.enable='1'
uci set wireless.default_radio0.mld='mld0'
uci set wireless.default_radio1.mld='mld0'
uci commit wireless
```

MLD MAC — локально администрируемый. В стоке используется `16:...`,
где последние 5 байт совпадают с MAC роутера.

---

## Установка

```sh
scp -r . root@192.168.1.1:/tmp/mlo/
ssh root@192.168.1.1 "sh /tmp/mlo/install.sh"
```

Скрипт сам:
- проверит окружение
- установит `/root/mlo-up` и `/etc/init.d/mlo`
- включит автозапуск
- поднимет MLO сразу, без перезагрузки

**Удаление:**

```sh
sh /tmp/mlo/install.sh uninstall
```

---

## Как это работает

### Ключевое отличие от обычной схемы

| | Обычно | Правильно |
|---|---|---|
| MLD-интерфейс | на `mld-phy0` | на `mld-phy0` ✓ |
| link-VDEV | на `mld-phy0` | на **физических** `phy1`/`phy2` |
| Параметр | `mld_iface` | **`mld_addr <MAC>`** |
| Bridge | все в `br-lan` | только `hostap_mld0` |
| hostapd | без `mld_*` | с `mld_mac_addr`, `mld_link_macs`, `mld_link_ids` |

Все четыре условия обязательны. Если убрать любое — MLO не поднимется.

### Последовательность

```sh
# 1. MLD на виртуальном phy
iw phy mld-phy0 interface add hostap_mld0 type __ap mld_addr 16:67:61:90:98:80
ip link set hostap_mld0 up
brctl addif br-lan hostap_mld0

# 2. линки на физических phy радио
iw phy phy1 interface add ath0 type __ap mld_addr 16:67:61:90:98:80   # 2,4 ГГц
iw phy phy2 interface add ath1 type __ap mld_addr 16:67:61:90:98:80   # 5 ГГц

# 3. hostapd с mld-параметрами в конфигах
hostapd -B hostapd-ath0.conf hostapd-ath1.conf
```

Соответствие phy:

```sh
cat /sys/class/net/wifi0/phy80211/name   # phy1 — 2,4 ГГц
cat /sys/class/net/wifi1/phy80211/name   # phy2 — 5 ГГц
cat /sys/class/net/wifi0/mldphy_name     # mld-phy0
```

---

## Диагностика

```sh
# 1. mld_addr заполнен у обоих линков
/root/iw_mld dev ath0 info | grep mld_addr
/root/iw_mld dev ath1 info | grep mld_addr

# 2. линки — slave'ы MLD
ip -d link show ath0 | head -1        # master hostap_mld0

# 3. драйвер зарегистрировал линки
dmesg | grep mlo_setup_link_ready
#   mld link 0 ... Valid link bitmap 1
#   mld link 1 ... Valid link bitmap 3

# 4. MLO attach
dmesg | grep mlo_ap_vdev_attach
#   mlo_ap_vdev_attach with LinkID: 1 num_links: 2
#   mlo_ap_vdev_attach with LinkID: 0 num_links: 2

# лог установщика
cat /tmp/mlo.log
```

### Если не работает

| Симптом | Причина |
|---|---|
| `Usage: iw phy ...` | используется системный `iw`, нужен `/root/iw_mld` |
| `mld_addr 00:00:00:00:00:00` | линк создан на `mld-phy0` вместо `phy1`/`phy2` |
| `mlo_ap_get_bridge_vdev_list: Invalid input` | нет MLD-контекста: линк создан не с `mld_addr` |
| `hostapd=0` | в конфигах нет `mld_*` или интерфейсы не созданы |
| файлы обнуляются | переполнен `/overlay` (`df -h /overlay`) |

---

## Ограничения

- **6 ГГц нет.** В RD15 регуляторный домен CN, `6G Channels: 0`, board data
  без калибровки 6 ГГц. Максимум — 2 линка (2,4 + 5).
- **После `wifi reload` / сохранения в LuCI** MLO слетает — netifd пересоздаёт
  интерфейсы. Помогает `/etc/init.d/mlo restart` или перезагрузка.
- **Гостевые сети** не входят в MLD и поднимаются отдельно (в текущей версии
  скрипт их не трогает).
- Проверено на одной конфигурации: RD15 + OpenWrt 25.12-SNAPSHOT r33336,
  ядро 5.4.213, QSDK 12.5.

---

## Технические детали

### Почему нужен вендорский iw

Системный `iw` знает только `managed`, `ibss`, `monitor`, `mesh`, `wds`.
Тип `__ap` и параметры `mld_addr` / `mld_iface` — расширения QSDK,
они есть только в `/root/iw_mld` (вендорская сборка iw 5.16).

### Что делает драйвер

При создании VDEV с `mld_addr` драйвер:

1. находит MLD-контекст (`wlan_mlo_dev_context`) по MAC;
2. регистрирует link-VDEV в этом контексте;
3. заполняет `mld_addr` у интерфейса;
4. привязывает VDEV как slave к bond-интерфейсу MLD;
5. при старте AP вызывает `mlo_ap_vdev_attach` для каждого линка.

Без шага 1 (`mlo_ap_get_bridge_vdev_list`) драйвер падает с `Invalid input`
и откатывается в режим «11be без MLO».

### Ссылки

- [OpenWrt 25.12-SNAPSHOT r33336](https://openwrt.org)
- QSDK 12.5 — `qcawificfg80211.sh`, функция создания VDEV
- Исходники hostapd QSDK: CodeLinaro `clo/qsdk/oss/system/feeds/wlan-hostapd`,
  ветка `NHSS.QSDK.12.5.r6`

---

## Лицензия

MIT. Используйте на свой риск: это неофициальная модификация, она не
поддерживается Xiaomi или OpenWrt.

---

## Патч для сборки прошивки

Если вы собираете прошивку сами — есть готовый патч:
[`patches/0001-ipq53xx-qcawifi-add-MLO-MLD-support.patch`](patches/0001-ipq53xx-qcawifi-add-MLO-MLD-support.patch)

Применяется к `qcawifi.sh` (netifd-скрипт Wi-Fi). Что делает:

- создаёт MLD-интерфейс до создания link-VDEV
- создаёт link-VDEV с `mld_addr` на физических phy
- не добавляет link-VDEV в bridge
- дописывает `mld_*` в конфиг hostapd

Включается тремя опциями UCI в секциях VAP:

```
option mld_mac '16:67:61:90:98:80'
option mld_link_macs '04:67:61:90:98:83 04:67:61:90:98:82'
option mld_link_ids '1 0'
```

Патч не тестировался в сборке (нет среды), но повторяет проверенную
на живом железе последовательность один в один.
