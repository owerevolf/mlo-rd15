# MLO (Wi-Fi 7 Multi-Link) на Xiaomi BE3600 2.5G (RD15) в OpenWrt — рабочее решение

**Проблема:** на стоковой прошивке Xiaomi BE3600 2.5G MLO работает, а в OpenWrt — нет.
**Решение:** найдено. MLO поднимается, клиент держит два диапазона одновременно.
**Как:** патч поверх сборки OpenWrt от RomikB. Прошивку пересобирать не нужно.

Если у вас Xiaomi BE3600 2.5G (RD15), Xiaomi BE3600 Pro, Cudy WR11000, GL.iNet Flint 3
или любое другое устройство на Qualcomm **IPQ5332 / IPQ5322** с QSDK 12.5 и OpenWrt —
этот материал может сэкономить вам недели.

---

## Результат

Клиент Realme Neo7 (Wi-Fi 7) подключается по двум линкам **одновременно**:

```
229 Мбит/с при частоте 2,4 ГГц
1921 Мбит/с при частоте 5 ГГц
```

Телефон показывает оба диапазона в свойствах сети и иконку Wi-Fi 7.
Обычное подключение так не выглядит — оно держит один диапазон.

dmesg подтверждает:

```
mlo_setup_link_ready: Pdev updated to Grp id 0 mld link 0 num_links 1 Valid link bitmap 1
mlo_setup_link_ready: Pdev updated to Grp id 0 mld link 1 num_links 2 Valid link bitmap 3
wlan_mlme_mlo_update_partner_info: mlo_ap_vdev_attach with LinkID: 1 num_links: 2
wlan_mlme_mlo_update_partner_info: mlo_ap_vdev_attach with LinkID: 0 num_links: 2
```

Проверено после перезагрузки — MLO поднимается автоматически.

---

## Кто это сделал

### Автор сборки OpenWrt

**Roman Zakharchuk (RomikB)**

- GitHub: **https://github.com/RomikB**
- Дерево сборки: **https://github.com/RomikB/openwrt** — ветка `openwrt-25-be3600`
- Профиль на 4PDA: https://4pda.to/forum/index.php?showuser=125083

Именно он создал target `ipq53xx`, портировал драйверы QSDK (`umac.ko`,
`qca_ol.ko`, `qdf.ko`), вендорский тулчейн GCC 7.5, NSS/PPE-ускорение и
netifd-скрипт `qcawifi.sh`. Без его работы MLO поднимать было бы не на чем.

### Тема на 4PDA

**Xiaomi Router BE3600 2,5G – обсуждение**

**https://4pda.to/forum/index.php?showtopic=1082660**

Там прошивки, восстановление после неудачных экспериментов, вопросы по SSH
и загрузке в слоты. Автор публикуется в этой теме.

### Что добавлено здесь

Только то, чего в сборке не было: **создание MLD-интерфейса и передача
`mld_addr` в link-VDEV**. Скрипт + патч. Всё остальное — труд автора сборки.

---

## С чего всё началось

Задача была простая: на стоке BE3600 MLO работает, в OpenWrt — нет.
При этом всё «железо» на месте:

| Компонент | Сток 1.0.106 | OpenWrt-сборка |
|---|---|---|
| Ядро | 5.4.213 | 5.4.213 |
| Драйвер Wi-Fi | `umac.ko` (QSDK 12.5) | тот же |
| Прошивки Wi-Fi | `q6_fw0/1/2`, `bdwlan.b13` | те же (md5 совпадают) |
| `qcawificfg80211.sh` | md5 `5397c62e…` | совпадает |
| `hostapd` | 1 231 688 байт | тот же размер, 25 MLO-строк совпадают один в один |

То есть драйвер, прошивки и даже hostapd — идентичны. Не хватало только
**правильной последовательности создания интерфейсов**.

---

## Как искали причину

Три подхода, два из них не сработали.

### 1. Подбор параметров — тупик

Пробовали менять `mld_ap`, `mld_id`, `mldev_mode_ap`, `cfg80211tool mld_addr`,
создавать link-VDEV с `mld_iface`, привязывать вручную через `ip link set master`.
Драйвер отвечал `Operation not permitted` или оставлял `mld_addr` нулевым.

### 2. Дизассемблирование драйвера — дало ответ

`umac.ko` собран stripped (имена функций вырезаны), но остались строки в
`.rodata`. По строке `mlo_ap_get_bridge_vdev_list` нашли функцию и восстановили
логику:

```c
if (!ctx)                goto invalid;      // ctx == NULL
mld = ctx->field_0x3f0;
if (!mld)                goto invalid;      // ← вот здесь падало

*count = 0;
for (node = mld->list_0x20; node != mld->list_end_0x28; node++) {
    vdev = *node;
    if (is_bridge_vdev(vdev) != 0) continue;
    out[*count] = vdev;
    (*count)++;
}
```

**Вывод:** `mlo_ap_get_bridge_vdev_list: Invalid input` означает не проблему
с Linux bridge (как часто советуют), а **отсутствие MLD-контекста в драйвере**.
Функция даже не доходит до перебора VDEV.

### 3. Чтение стоковых скриптов — дало решение

В стоковой прошивке `/lib/wifi/qcawificfg80211.sh` нашлась настоящая
последовательность:

```sh
config_get mld_mac "$mld" mld_macaddr
if [ -z "$mld_mac" ]; then
    iw phy "$(cat /sys/class/net/$phy/phy80211/name)" \
        interface add $ifname type $wlanmode mld_iface $mld
else
    iw phy "$(cat /sys/class/net/$phy/phy80211/name)" \
        interface add $ifname type $wlanmode mld_addr $mld_mac
fi
```

Два ключевых момента:
- `$phy` — это **физическое радио** (`wifi0`/`wifi1`), а не `mld-phy0`
- используется **`mld_addr <MAC>`**, а не `mld_iface`

И там же про bridge:

```sh
config_get ifmld "$vif" mld
if [ -z $ifmld ]; then
    config_set "$vif" bridge "$bridge"
fi
```

VIF, входящий в MLD, **не добавляется в bridge**.

---

## Четыре условия (все обязательны)

| # | Условие | Почему |
|---|---|---|
| 1 | Link-VDEV на **физических** `phy1`/`phy2` | на `mld-phy0` создаётся только MLD-интерфейс |
| 2 | Параметр **`mld_addr <MAC>`**, не `mld_iface` | именно он заставляет драйвер создать `wlan_mlo_dev_context` |
| 3 | В `br-lan` только `hostap_mld0` | link-VDEV в bridge ломают MLD |
| 4 | В конфиге hostapd — `mld_mac_addr`, `mld_link_macs`, `mld_link_ids` | netifd их не пишет |

Убрать любое — драйвер откатывается в «11be без MLO» с ошибкой
`mlo_ap_get_bridge_vdev_list: Invalid input`.

---

## Установка

### Требования

- Роутер Xiaomi BE3600 2.5G (**RD15**), SoC IPQ5332
- OpenWrt-сборка RomikB, ветка `openwrt-25-be3600`
- Вендорский `iw`, умеющий `mld_addr` и `type __ap` (системный не умеет)
- Клиент с поддержкой MLO (Wi-Fi 7 + multi-link)

> **Готовых образов в репозитории автора нет** — прошивка собирается
> из ветки `openwrt-25-be3600` самостоятельно либо запрашивается у автора
> в теме на 4PDA. Этот репозиторий содержит только надстройку для MLO.

### Быстрая установка

```sh
scp -r . root@192.168.1.1:/tmp/mlo/
ssh root@192.168.1.1 "sh /tmp/mlo/install.sh"
```

Скрипт сам проверит окружение, установит `/root/mlo-up`, включит автозапуск
и поднимет MLO без перезагрузки.

**Удаление:**

```sh
sh /tmp/mlo/install.sh uninstall
```

### Ручная проверка

```sh
# 1. MLD-интерфейс на mld-phy0
iw phy mld-phy0 interface add hostap_mld0 type __ap mld_addr 16:67:61:90:98:80
ip link set hostap_mld0 up
brctl addif br-lan hostap_mld0

# 2. Линки на физических phy радио
iw phy phy1 interface add ath0 type __ap mld_addr 16:67:61:90:98:80   # 2,4 ГГц
iw phy phy2 interface add ath1 type __ap mld_addr 16:67:61:90:98:80   # 5 ГГц

# 3. Проверка
iw dev ath0 info | grep mld_addr     # должен быть не нулевой
ip -d link show ath0 | head -1       # master hostap_mld0

# 4. hostapd с mld-параметрами в конфигах
hostapd -B /var/run/hostapd-ath0.conf /var/run/hostapd-ath1.conf
```

Соответствие phy:

```sh
cat /sys/class/net/wifi0/phy80211/name   # phy1 — 2,4 ГГц
cat /sys/class/net/wifi1/phy80211/name   # phy2 — 5 ГГц
cat /sys/class/net/wifi0/mldphy_name     # mld-phy0
```

---

## Как проверить, что MLO поднялся

```sh
# 1. mld_addr заполнен у обоих линков
iw dev ath0 info | grep mld_addr
iw dev ath1 info | grep mld_addr

# 2. линки — slave'ы MLD
ip -d link show ath0 | head -1        # master hostap_mld0

# 3. драйвер зарегистрировал оба линка
dmesg | grep mlo_setup_link_ready
#   mld link 0 ... Valid link bitmap 1
#   mld link 1 ... Valid link bitmap 3

# 4. MLO attach
dmesg | grep mlo_ap_vdev_attach
#   mlo_ap_vdev_attach with LinkID: 1 num_links: 2
#   mlo_ap_vdev_attach with LinkID: 0 num_links: 2
```

На клиенте: в свойствах Wi-Fi должны отображаться **оба диапазона**.

### Если не работает

| Симптом | Причина |
|---|---|
| `Usage: iw phy ...` | используется системный `iw`, нужен вендорский |
| `mld_addr 00:00:00:00:00:00` | линк создан на `mld-phy0` вместо `phy1`/`phy2` |
| `mlo_ap_get_bridge_vdev_list: Invalid input` | нет MLD-контекста — линк создан не с `mld_addr` |
| `hostapd=0` | в конфигах нет `mld_*` или интерфейсы не созданы |
| файлы обнуляются | переполнен `/overlay` (`df -h /overlay`) |

---


## ⚠️ Важно: PMF не делайте обязательным

Самая частая проблема после включения MLO — **перестают подключаться старые устройства**
(телевизоры, умные колонки, роботы-пылесосы). Симптом: устройство видит сеть,
но не подключается, в логах hostapd при этом тишина.

Причина — `ieee80211w=2` (**обязательный** PMF). Для MLO нужен PMF, но не нужен
именно обязательный режим.

Правильно:

```
option encryption 'psk2'
option ieee80211w '1'
```

`1` = PMF опциональный: устройства с поддержкой используют его, остальные
подключаются как обычно. MLO при этом работает.

Если поставить `2` — подключатся только устройства с PMF, остальные молча
отвалятся. Проверено на LG webOS TV, SberBoom Mini и роботе-пылесосе:
с `2` они не проходят ассоциацию, с `1` — работают нормально.

---

## Ограничения

- **6 ГГц нет.** На RD15 регуляторный домен `CN`, драйвер сообщает
  `6G Channels: 0`, board data (`bdwlan.b13`) без калибровки 6 ГГц.
  Даже при смене домена каналы не появятся — калибровки нет.
  Максимум — **2 линка: 2,4 + 5 ГГц**.
- **После `wifi reload` / сохранения в LuCI** MLO слетает: netifd пересоздаёт
  интерфейсы. Лечится `/etc/init.d/mlo restart`.
- **Гостевые сети** в MLD не входят — поднимаются отдельно.
- Проверено на одной конфигурации: RD15 + OpenWrt 25.12-SNAPSHOT r33336,
  ядро 5.4.213, QSDK 12.5, клиент Realme Neo7.

---

## Файлы

| Файл | Что это |
|---|---|
| `mlo-up` | Скрипт поднятия MLO (с откатом при неудаче) |
| `mlo-init` | Init-скрипт автозапуска (`/etc/init.d/mlo`) |
| `install.sh` | Установщик / удалятор |
| `patches/0001-…patch` | Патч к `qcawifi.sh` для сборки прошивки |
| `patches/qcawifi-patched.sh` | Готовая версия пропатченного скрипта |

---

## Благодарности

**Roman Zakharchuk (RomikB)** — за сборку OpenWrt для RD15, без которой
ничего бы не было: target `ipq53xx`, драйверы QSDK, netifd-скрипты,
вендорский тулчейн.

Сообщество **4PDA**, тема «Xiaomi Router BE3600 2,5G – обсуждение» —
за прошивки, восстановление и ответы на вопросы.

**perceival** (https://github.com/perceival/openwrt-flint3) — за подтверждение,
что MLO на IPQ5332 в mainline работает; это дало уверенность, что дело
не в железе.

---

## Лицензия

MIT. Неофициальная модификация. Не поддерживается Xiaomi или OpenWrt.
Используйте на свой риск и обязательно сохраните возможность отката
(слот со стоковой прошивкой).
