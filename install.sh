#!/bin/sh
# Установщик MLO для Xiaomi BE3600 (RD15) на OpenWrt 25.x
#
# Что делает:
#   1. проверяет окружение (вендорский iw, UCI-секция mld)
#   2. копирует /usr/... скрипты
#   3. включает автозапуск
#   4. запускает MLO сразу (без перезагрузки)
#
# Удаление:  sh install.sh uninstall

set -e

SRC_DIR=$(dirname "$0")
IWL="/root/iw_mld"

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[X] $*"; }

if [ "$1" = "uninstall" ]; then
    info "удаляю автозапуск"
    /etc/init.d/mlo disable 2>/dev/null || true
    /etc/init.d/mlo stop 2>/dev/null || true
    rm -f /etc/init.d/mlo /root/mlo-up
    info "возвращаю обычный Wi-Fi"
    killall hostapd 2>/dev/null || true
    for d in ath0 ath1 hostap_mld0; do $IWL dev "$d" del 2>/dev/null || true; done
    wifi up >/dev/null 2>&1 || true
    info "готово. Перезагрузка не нужна."
    exit 0
fi

echo "=== Проверка окружения ==="

if [ ! -f "$IWL" ]; then
    err "не найден вендорский iw: $IWL"
    err "без него MLO не поднять — он умеет mld_addr и type __ap"
    exit 1
fi
info "вендорский iw найден"

if [ -z "$(uci -q get wireless.mld0.mld_macaddr)" ]; then
    err "в UCI нет секции wireless.mld0 с mld_macaddr"
    err "создайте её:"
    cat <<'EOF'
    uci set wireless.mld0=wifi-mld
    uci set wireless.mld0.mld_macaddr='16:67:61:90:98:80'
    uci set wireless.mld0.link_mac='<mac_5g> <mac_24>'
    uci set wireless.mld0.link_id='1 0'
    uci set wireless.mld0.enable='1'
    uci set wireless.default_radio0.mld='mld0'
    uci set wireless.default_radio1.mld='mld0'
    uci commit wireless
EOF
    exit 1
fi
info "UCI-секция mld0 есть: $(uci -q get wireless.mld0.mld_macaddr)"

# --- Совместимость: PMF не должен быть обязательным ---
# При ieee80211w=2 (обязательный PMF) старые устройства — телевизоры,
# умные колонки, роботы-пылесосы — молча не проходят ассоциацию.
# Для MLO достаточно ieee80211w=1 (опциональный).
NEED_COMMIT=0
for r in default_radio0 default_radio1; do
    [ -n "$(uci -q get wireless.$r)" ] || continue
    cur_pmf=$(uci -q get wireless.$r.ieee80211w)
    if [ "$cur_pmf" = "2" ]; then
        warn "$r: ieee80211w=2 (обязательный PMF) — старые устройства не подключатся"
        uci set wireless.$r.ieee80211w='1'
        NEED_COMMIT=1
    fi
done
if [ "$NEED_COMMIT" = "1" ]; then
    uci commit wireless
    info "PMF переключён на опциональный (ieee80211w=1)"
else
    info "PMF уже опциональный или не задан — ок"
fi

# флеш-память
FREE=$(df -k /overlay | awk 'NR==2 {print $4}')
if [ "$FREE" -lt 2000 ]; then
    warn "на /overlay мало места ($FREE КБ), файлы могут не записаться"
fi

echo ""
echo "=== Установка ==="
cp "$SRC_DIR/mlo-up" /root/mlo-up
chmod +x /root/mlo-up
cp "$SRC_DIR/mlo-init" /etc/init.d/mlo
chmod +x /etc/init.d/mlo
sync
info "скрипты установлены"

/etc/init.d/mlo enable
info "автозапуск включён"

echo ""
echo "=== Запуск MLO ==="
sh /root/mlo-up
RC=$?

if [ $RC -eq 0 ] && dmesg | grep -q "mlo_ap_vdev_attach"; then
    echo ""
    info "MLO работает"
    dmesg | grep "mlo_ap_vdev_attach" | tail -2
else
    echo ""
    err "MLO не поднялся, смотрите /tmp/mlo.log"
    tail -20 /tmp/mlo.log 2>/dev/null
fi
