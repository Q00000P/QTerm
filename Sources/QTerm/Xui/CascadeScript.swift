// Сгенерировано scripts/gen-mac-embed.sh из scripts/vpn-cascade.sh — не править руками.
// Скрипт сервера qcascade: QTerm заливает его на каскад-сервер сам (окно «Каскад»).
enum CascadeScript {
    static let text = ##"""
#!/usr/bin/env bash
# qcascade — каскад на VPS с 3x-ui (и awg-panel): трафик клиентов VLESS / Hysteria / AWG и MTProto-прокси → mihomo
# с правилами как на Кинетиках → ноды из источников: свои клиенты на панелях 3x-ui, ссылки подписок, WireGuard/AmneziaWG.
#
#   qcascade install                 установка (визард; без tty — из переменных QC_*)
#   qcascade apply                   пересобрать конфиг mihomo по источникам, группам и правилам (проверка, откат при сбое)
#   qcascade refresh                 то же, только если что-то изменилось (таймер раз в час)
#   qcascade status [--json]         состояние: mihomo, источники, группы, перехват
#   qcascade sources get | set -     источники нод (JSON; set читает stdin — секреты не светятся в ps)
#   qcascade xray on|off|show|list   перехват клиентов 3x-ui (list — инбаунды и клиенты, JSON)
#   qcascade detect                  что есть на сервере: 3x-ui, интерфейсы AWG, MTProto-прокси (JSON)
#   qcascade nf up|down|sync|status  сетевой перехват AWG-интерфейсов и MTProto (зовёт сам сервис)
#   qcascade set K=V… | set -        настройки (QC_DIRECT_TARGET, QC_XRAY_MODE, QC_AWG_MODE, QC_MTP, QC_RESERVE…)
#   qcascade config                  визард
#   qcascade update-core             обновить ядро mihomo (с проверкой и откатом)
#   qcascade logs [N]                журнал mihomo
#   qcascade uninstall [--purge]
#
# Секреты (ссылки подписок, ключи WireGuard, secret API) — только в /etc/qcascade (600) на сервере.
# Неинтерактивно: QC_SUB_URL (первый источник), QC_DIRECT_TARGET, QC_XRAY_MODE=all|inbounds|users|off, QC_XRAY_LIST,
# QC_AWG_MODE=off|all|list + QC_AWG_IFACES, QC_MTP=on|off, QC_RESERVE, QC_MIHOMO_URL / QC_MIHOMO_REPO + QC_GH_TOKEN,
# QC_SOURCES_FILE (JSON источников для install; файл удаляется).

set -Eeuo pipefail
VERSION="2.0.0"

QC_ROOT=${QC_ROOT:-}            # только для тестов: префикс всех путей
QC_ETC=$QC_ROOT/etc/qcascade
QC_HOME=$QC_ROOT/var/lib/qcascade
QC_LIB=$QC_ROOT/usr/local/lib/qcascade
QC_BIN=$QC_LIB/mihomo
QC_SELF=$QC_ROOT/usr/local/sbin/qcascade
ENV_FILE=$QC_ETC/env
CFG=$QC_ETC/config.yaml
RULES=$QC_ETC/rules.yaml
GROUPS_F=$QC_ETC/groups.conf
SOURCES=$QC_ETC/sources.json
RSDIR=$QC_ETC/rule-sets
STATE=$QC_HOME/state.json
PROV_DIR=$QC_HOME/providers
TG_CIDR=$QC_HOME/telegram-cidr.txt
BK=$QC_ETC/backup
SVC=qcascade
XUI_DIR=${XUI_DIR:-/usr/local/x-ui}
ENV_KEYS="QC_SECRET QC_PORT QC_API QC_TPROXY_PORT QC_DIRECT_TARGET QC_XRAY_MODE QC_XRAY_LIST QC_AWG_MODE QC_AWG_IFACES QC_AWG_SRC QC_MTP QC_MTP_USERS QC_RESERVE QC_MIHOMO_URL QC_MIHOMO_REPO"

# сетевой перехват: метка пакетов, таблица маршрутов, приоритет правила (менять — только вместе: nf down → nf up)
NF_MARK=0x2a0
NF_TABLE=672
NF_PREF=9000
NF_NAME=qcascade
NF_SAVED=$QC_HOME/nf.rules
# ───────────────────────────── вывод ─────────────────────────────
if [ -t 1 ]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_G=; C_Y=; C_R=; C_B=; C_0=; fi
QUIET=0
CLEAN=()
trap 'rm -rf "${CLEAN[@]}" 2>/dev/null || true' EXIT
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
ok()   { [ "$QUIET" = 1 ] || printf '%s[ok]%s  %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!!]%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[ERR]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { [ "$QUIET" = 1 ] || printf '\n%s── %s%s\n' "$C_B" "$*" "$C_0"; }

need_root() { [ "$(id -u)" = 0 ] || die "нужен root"; }

# ───────────────────────────── ввод ─────────────────────────────
# Backspace от автопереключателя раскладки приходит литеральным 0x7f — чистим сами.
clean_in() {
  local s=$1 out="" c i
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      $'\x7f'|$'\b') out=${out%?} ;;
      $'\r') ;;
      *) [[ "$c" == [[:cntrl:]] ]] || out+=$c ;;
    esac
  done
  printf '%s' "$out"
}
drain_input() { local x; while read -r -s -t 0.05 -n 256 x 2>/dev/null; do :; done; }
ask() { # ask VAR "вопрос" [по умолчанию]
  local __v=$1 q=$2 d=${3:-} a
  drain_input
  if [ -n "$d" ]; then read -r -p "$q [$d]: " a </dev/tty || true; else read -r -p "$q: " a </dev/tty || true; fi
  a=$(clean_in "$a"); a=${a#"${a%%[![:space:]]*}"}; a=${a%"${a##*[![:space:]]}"}
  [ -n "$a" ] || a=$d
  printf -v "$__v" '%s' "$a"
}
interactive() { [ -t 0 ] && [ -r /dev/tty ] && [ "${QC_NONINTERACTIVE:-0}" != 1 ]; }


# ───────────────────────────── env ─────────────────────────────
# Значения из окружения при запуске важнее файла.
load_env() {
  local line k
  [ -f "$ENV_FILE" ] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^(QC_[A-Z_]+)= ]] || continue
    k=${BASH_REMATCH[1]}
    [ -n "${!k+x}" ] && continue
    eval "$line"
  done < "$ENV_FILE"
}
save_env() {
  local k tmp
  install -d -m 755 "$QC_ETC"
  tmp=$(mktemp "$QC_ETC/.env.XXXX")
  {
    echo "# qcascade — секреты и настройки. Права 600, в гит/гисты не выкладывать."
    for k in $ENV_KEYS; do printf '%s=%q\n' "$k" "${!k:-}"; done
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$ENV_FILE"
}
defaults() {
  : "${QC_PORT:=7893}" "${QC_API:=127.0.0.1:9090}" "${QC_TPROXY_PORT:=7895}" "${QC_DIRECT_TARGET:=DIRECT}" \
    "${QC_XRAY_MODE:=all}" "${QC_XRAY_LIST:=}" "${QC_AWG_MODE:=off}" "${QC_AWG_IFACES:=}" "${QC_AWG_SRC:=}" \
    "${QC_MTP:=off}" "${QC_MTP_USERS:=telemt mtproxy}" "${QC_RESERVE:=}" \
    "${QC_MIHOMO_URL:=}" "${QC_MIHOMO_REPO:=}" "${QC_SUB_URL:=}"
  [ -n "${QC_SECRET:-}" ] || QC_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
}

# ───────────────────────────── зависимости ─────────────────────────────
deps() {
  local miss=() b
  for b in curl jq sqlite3 gzip ss ip nft; do command -v "$b" >/dev/null || miss+=("$b"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  command -v apt-get >/dev/null || die "нет: ${miss[*]} (и нет apt-get)"
  say "ставлю: ${miss[*]}"
  local pk=() m
  for m in "${miss[@]}"; do case $m in ss|ip) pk+=(iproute2) ;; nft) pk+=(nftables) ;; *) pk+=("$m") ;; esac; done
  local log; log=$(mktemp); CLEAN+=("$log")
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$log" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pk[@]}" ca-certificates >>"$log" 2>&1 \
    || { tail -5 "$log" >&2; die "не поставились пакеты: ${pk[*]}"; }
}
port_busy() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q . || ss -Hlun "( sport = :$1 )" 2>/dev/null | grep -q .; }
pick_port() { local p=$1; while port_busy "$p"; do p=$((p+1)); done; echo "$p"; }
# ───────────────────────────── ядро mihomo ─────────────────────────────
mh_arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7*|armhf) echo armv7 ;;
    i?86) echo 386 ;;
    *) die "архитектура $(uname -m) не поддержана" ;;
  esac
}
mh_latest_tag() {
  local t
  t=$(curl -fsSI --max-time 20 https://github.com/MetaCubeX/mihomo/releases/latest 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="location:"{n=split($2,a,"/"); print a[n]}' | tail -1)
  [[ "$t" == v* ]] || t=$(curl -fsS --max-time 20 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
      | jq -r '.tag_name // empty' 2>/dev/null || true)
  [[ "$t" == v* ]] || return 1
  echo "$t"
}
# fetch_core <куда>: свой URL → приватный релиз → стоковый MetaCubeX
fetch_core() {
  local out=$1 tmp arch url tag
  tmp=$(mktemp -d); arch=$(mh_arch)
  if [ -n "$QC_MIHOMO_URL" ]; then
    url=$QC_MIHOMO_URL
    curl -fL --max-time 300 -sS -o "$tmp/m" "$url" || { rm -rf "$tmp"; die "не скачал ядро: $url"; }
  elif [ -n "$QC_MIHOMO_REPO" ]; then
    [ -n "${QC_GH_TOKEN:-}" ] || warn "QC_MIHOMO_REPO задан без QC_GH_TOKEN — приватный релиз не скачается"
    local api=https://api.github.com/repos/$QC_MIHOMO_REPO/releases/latest id
    local auth=(); [ -n "${QC_GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $QC_GH_TOKEN")
    id=$(curl -fsS --max-time 30 "${auth[@]}" "$api" \
         | jq -r --arg a "linux-$arch" '[.assets[]|select(.name|test($a))][0].id // empty' 2>/dev/null || true)
    if [ -z "$id" ]; then
      warn "в $QC_MIHOMO_REPO нет сборки linux-$arch — беру стоковый mihomo"
      QC_MIHOMO_REPO=""; rm -rf "$tmp"; fetch_core "$out"; return
    fi
    curl -fL --max-time 300 -sS "${auth[@]}" -H "Accept: application/octet-stream" \
      -o "$tmp/m" "https://api.github.com/repos/$QC_MIHOMO_REPO/releases/assets/$id" \
      || { rm -rf "$tmp"; die "не скачал релиз из $QC_MIHOMO_REPO"; }
  else
    tag=$(mh_latest_tag) || { rm -rf "$tmp"; die "не узнал последнюю версию mihomo (GitHub недоступен?)"; }
    local name=$arch; [ "$arch" = amd64 ] && name=amd64-compatible
    url=https://github.com/MetaCubeX/mihomo/releases/download/$tag/mihomo-linux-$name-$tag.gz
    curl -fL --max-time 300 -sS -o "$tmp/m" "$url" || { rm -rf "$tmp"; die "не скачал $url"; }
  fi
  if gzip -t "$tmp/m" 2>/dev/null; then gzip -dc "$tmp/m" > "$tmp/bin"; else mv "$tmp/m" "$tmp/bin"; fi
  chmod 755 "$tmp/bin"
  "$tmp/bin" -v >/dev/null 2>&1 || { rm -rf "$tmp"; die "скачанное ядро не запускается"; }
  install -d -m 755 "$(dirname "$out")"; mv -f "$tmp/bin" "$out"; rm -rf "$tmp"
}
mh_ver() { "$QC_BIN" -v 2>/dev/null | awk 'NR==1{print $3}'; }

# ───────────────────────────── правила по умолчанию (как на Кинетике) ─────────────────────────────
write_default_rules() {
  [ -f "$RULES" ] && return 0
  cat > "$RULES" <<'EOF'
# Правила — тот же формат, что в config.yaml Кинетика: секции rule-providers и rules.
# Пути /opt/etc/mihomo/... и ./rule-sets/... переписываются автоматически.
# Провайдеры type: file берутся из /etc/qcascade/rule-sets/<имя файла>.mrs (свои .mrs Кинетика
# встроены в скрипт); если файла нет — провайдер и его правила пропускаются (видно в qcascade status).
# После правки: qcascade apply

rule-providers:
  ip-checkers:
    type: file
    behavior: domain
    format: mrs
    path: /opt/etc/mihomo/rule-sets/ip-checkers.mrs

  max-domains:
    type: file
    behavior: domain
    format: mrs
    path: /opt/etc/mihomo/rule-sets/max-domains.mrs

  max-ip:
    type: file
    behavior: ipcidr
    format: mrs
    path: /opt/etc/mihomo/rule-sets/max-ip.mrs

  apple-push:
    type: file
    behavior: domain
    format: mrs
    path: /opt/etc/mihomo/rule-sets/apple-push.mrs

  google-fcm:
    type: file
    behavior: domain
    format: mrs
    path: /opt/etc/mihomo/rule-sets/google-fcm.mrs

  bosh:
    type: file
    behavior: domain
    format: mrs
    path: ./rule-sets/bosh.mrs

  hagezi_pro:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.mrs
    path: ./adblock/adlist.mrs
    interval: 86400

  ads:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-ads-all.mrs"
    path: ./rule-providers/ads.mrs
    interval: 86400

  ru_sites:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-ru.mrs"
    path: ./rule-providers/ru_sites.mrs
    interval: 86400

  youtube:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/youtube.mrs"
    path: ./rule-providers/youtube.mrs
    interval: 86400

  google_services:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google.mrs"
    path: ./rule-providers/google_services.mrs
    interval: 86400

  geosite-private:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.mrs
    path: ./geosite-private.mrs
    interval: 86400

  geoip-private:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.mrs
    path: ./geoip-private.mrs
    interval: 86400

  geoip_ru:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/ru.mrs"
    path: ./rule-providers/geoip_ru.mrs
    interval: 86400

  openai:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/openai.mrs"
    path: ./rule-providers/openai.mrs
    interval: 86400

  perplexity:
    type: file
    behavior: domain
    format: mrs
    path: ./rule-sets/perplexity.mrs

  claude:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/anthropic.mrs"
    path: ./rule-providers/anthropic.mrs
    interval: 86400

  facebook:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/facebook.mrs"
    path: ./ruleset/facebook.mrs
    interval: 86400

  facebook-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/facebook.mrs"
    path: ./ruleset/facebook-ip.mrs
    interval: 86400

  instagram:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/instagram.mrs"
    path: ./rule-providers/instagram.mrs
    interval: 86400

  twitter:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/twitter.mrs"
    path: ./rule-providers/twitter.mrs
    interval: 86400

  google_play:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google-play.mrs"
    path: ./rule-providers/google_play.mrs
    interval: 86400

  microsoft:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft.mrs"
    path: ./rule-providers/microsoft.mrs
    interval: 86400

  tg:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/telegram.mrs"
    path: ./rule-providers/telegram.mrs
    interval: 86400

  tg-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs"
    path: ./rule-providers/telegram-ip.mrs
    interval: 86400

  whatsapp:
    type: file
    behavior: domain
    format: mrs
    path: /opt/etc/mihomo/rule-sets/whatsapp.mrs

  whatsapp-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/zxc-rv/assets/raw/refs/heads/main/rules/meta-ips.mrs
    path: ./provider/rule-set/meta-ip.mrs
    interval: 86400

  discord:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/discord.mrs"
    path: ./rule-providers/discord.mrs
    interval: 86400

  category_gov_ru:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-gov-ru.mrs"
    path: ./rule-providers/category-gov-ru.mrs
    interval: 86400

  yandex:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/yandex.mrs"
    path: ./rule-providers/yandex.mrs
    interval: 86400

  google-gemini:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google-gemini.mrs"
    path: ./rule-providers/google-gemini.mrs
    interval: 86400

  geosite-github:
    type: http
    behavior: domain
    format: mrs
    path: ./rule-providers/geosite-github.mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/github.mrs"
    interval: 86400

  twitch:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/twitch.mrs"
    path: ./rule-providers/twitch.mrs
    interval: 86400

  media_ru:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-media-ru.mrs"
    path: ./rule-providers/media_ru.mrs
    interval: 86400

  bundle:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rule.mrs
    path: ./ru-bundle/rule.mrs
    interval: 86400

  torrent-clients:
    type: http
    url: 'https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/refs/heads/main/other/torrent-clients.yaml'
    interval: 86400
    proxy: DIRECT
    behavior: classical
    format: yaml
  torrent-trackers:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-trackers.mrs
    path: ./rule-sets/torrent-trackers.mrs
    interval: 86400

  refilter_domains:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/domain-rule.mrs
    path: ./re-filter/domain-rule.mrs
    interval: 86400

  refilter_ipsum:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/ip-rule.mrs
    path: ./re-filter/ip-rule.mrs
    interval: 86400

  torrent-websites:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-websites.mrs
    path: ./rule-sets/torrent-websites.mrs
    interval: 86400

  zoom:
    type: file
    path: /opt/etc/mihomo/rule-sets/zoom.mrs
    behavior: domain
    format: mrs
    interval: 86400

  quic:
    type: inline
    behavior: classical
    payload:
      - AND,((NETWORK,udp),(DST-PORT,443))

rules:
#     Youtube
  - RULE-SET,youtube,MSK
  - DOMAIN-SUFFIX,myip.ms,DIRECT
  - DOMAIN-SUFFIX,myip.fi,DIRECT
  - DOMAIN-SUFFIX,myip.nl,DIRECT
  - DOMAIN-SUFFIX,myip.com,MSK
  - DOMAIN-SUFFIX,myip.uz,DIRECT
  - DOMAIN-SUFFIX,myip.qa,DIRECT
  - DOMAIN,myip.ch,SP

#       MAX
  - RULE-SET,max-domains,REJECT
  - RULE-SET,max-ip,REJECT

#     Блок рекламы, RULE-SET,quic  REJECT
#  - OR,((RULE-SET,hagezi_pro),(RULE-SET,ads),(RULE-SET,quic)),REJECT
  - RULE-SET,hagezi_pro,REJECT
  - RULE-SET,ads,REJECT
  - RULE-SET,quic,REJECT
  - DOMAIN-SUFFIX,adobedtm.com,REJECT

  - RULE-SET,facebook,FII
  - RULE-SET,facebook-ip,FII
  - RULE-SET,whatsapp,FII
  - RULE-SET,whatsapp-ip,FII
  - DOMAIN-SUFFIX,my.telegram.org,FII
  - RULE-SET,tg-ip,TG
  - RULE-SET,tg,TG
  - RULE-SET,zoom,FII
  - DOMAIN-SUFFIX,stacksocial.com,FI

#     Российский трафик & блокировки
  - RULE-SET,category_gov_ru,DIRECT
  - RULE-SET,yandex,DIRECT
  - RULE-SET,ru_sites,DIRECT
  - RULE-SET,geoip_ru,DIRECT
  - RULE-SET,bosh,EU
  - RULE-SET,media_ru,DIRECT

  - RULE-SET,bundle,T
  - MATCH,DIRECT
EOF
}

write_default_groups() {
  [ -f "$GROUPS_F" ] && return 0
  cat > "$GROUPS_F" <<'EOF'
# Составные группы — как на Кинетиках. Строка:
#   ИМЯ  ТИП  ИНТЕРВАЛ  УЧАСТНИКИ...
# ТИП: fallback | url-test | select | load-balance. ИНТЕРВАЛ — проверка, сек.
# УЧАСТНИКИ — имена нод подписки или других групп, по приоритету.
# На каждую ноду подписки группа с тем же именем создаётся сама (в правилах можно писать FI, US3-HYS…).
# Участники, которых нет в подписке, пропускаются; группа без участников уходит в DIRECT (видно в status).
# После правки: qcascade apply
TG   fallback 10  FI FI-HYS FI-N-HYS DE DE-HYS SP SP-HYS US3-HYS NL1 NL1-HYS NL2 NL2-HYS NL3 NL3-HYS
EU   fallback 60  FI FI-HYS FI-N-HYS DE DE-HYS SP SP-HYS US3-HYS NL1 NL1-HYS NL2 NL2-HYS NL3 NL3-HYS
USA  fallback 60  US US-HYS US2 US2-HYS US3 US3-HYS
USS  fallback 60  US US-HYS
FII  fallback 60  FI FI-HYS FI-N-HYS
T    fallback 60  LV LV-HYS
MSK  fallback 60  MSK MSK-HYS
NL   fallback 60  NL1 NL1-HYS NL2 NL2-HYS NL3 NL3-HYS
EOF
}

# ───────────────────────────── локальные rule-sets с Кинетика ─────────────────────────────
# Свои .mrs роутеров (type: file), встроены, чтобы не таскать руками. Кладутся, только если файла
# ещё нет — свою версию положи в /etc/qcascade/rule-sets/ и она не перезапишется.
# zoom.mrs собран из zoom.us / zoom.com / zoomgov.com (+ поддомены).
install_bundled_rulesets() {
  local name b64
  install -d -m 755 "$RSDIR"
  while read -r name b64; do
    [ -n "$name" ] || continue
    [ -s "$RSDIR/$name.mrs" ] && continue
    printf '%s' "$b64" | base64 -d > "$RSDIR/$name.mrs.tmp" && mv -f "$RSDIR/$name.mrs.tmp" "$RSDIR/$name.mrs"
    chmod 644 "$RSDIR/$name.mrs"
  done <<'RULESETS'
ip-checkers KLUv/WRuA10ZAApBEAw9IHEaAB+QwyrkL8AmwdjQr/GhQ543z4wS2S3fb72/lN2dMn3+BIMdUxRBcBFOIyXvWIOAIP3+dx5K2Nj2D+UAoQCgAPsg7QDQJgoNnUprrZOS4mLSIOGUcOjMzIPCoYMGFJSRTovJmZ1nw4w5pwiH5EGZz4yHM2fIw0GZc+TpzPlwRp6HQufkifA88+mwmHOScGaLEZQ5SeacFZ7n4cyUOUtqzJSS53mmijlDWMwVKuaAGTJlzBEKCwKIPCPPihIiAUCeEQ3keZ5ZIcCBASBCnqYiBIOIiTkRtBYjREVFUDEkcJwQcOAFAggWBxM4OlqCjg4L1MBA22gpGFRag1GptA1LgY2OjWax0Ca0jVYBUdBItNY8NBCOZmmNo1KxWFrbaARKWiVDyIVXw4hX4UYqLzMnGawun1Sv/OZLnxfq6HA7/sPDwuxip/irWNTZRn9m5QzmAr8qqTYkVVKTayMvmNnH2PmvT64II430YxYDJen0QZfdJDbDKhNB2Km+uuTQYpf49WWsXOzLTF6xYeYbQR9ZwwcvnZrep79dbL67YjPMfNoI8+yTOiebpwfY9oNuB51z6qB77O6cc3Ex633pcbSid1WYvJqtKVjL6x8eS2l+uWRV/Ou+6nvPzSZSY/yVMHrSUUeuZAX5JdG9bt3LZ/rrl27lpV83XLVW7/fcZmqT6i/T/FXR1dN7ZzhGW0HZMrW5Lhhpdb339mXSC/ny6ZLvYd2QYmslBquKf2qnTbZhq/V1M0+S+rmjhI9wM/lYLVZIYlL2pYKeJV2C793+ly9bo4k4k71PchleVjfzUhXF2SUFL/BhxwJ/t0bz4fE2e1GKMnmvygj/LuOnlS7T3550dSH9pcuCLOvDNld/nN4d9a0sXptdMX6lVTfcT9OnCTqYnd8vm31DesfamUajutzTRk76bku/dHpvtH9qY6KNmS6pan1S+1L04dEt/6qVCmls5hj7lbXtrsmK+l0qZVcr4x103f5HXPe7xpgvt7/uFf9KxfdqVN7VvSglpT3z40orDwANBAbCCMgFRUF4wFhxh6G5ogoiVgaLOR4gXZMYC2Fk7g2av10y
max-domains KLUv/QQAfQIA1ANNUlMBAAUBAAAAAgiCIAKq1apaWlVVKgAGAAAhdXIuZXhtYWVtbi5vK2kucCtpYXAtdGFtb3Jib2Z0YWxwBgApAsscZyfhmiRYyCVzWtXjCgQ=
max-ip KLUv/UQAHgFlBQDSRhkjkAsEqJbAdg7o8keLZJAxxBeWCSGGbpKkTpgNMVUaj067zfMMc4phdmKYTwyzlDvHuLOb587nzkqtalXbgkZDgwKVLjTN/CKKeuZYEnUsdRC9zPgcOqVPuqSQB6H96AGvZSgMAiYgcMPAAYMzGG00o41+o8GuPoAa+LCMOUweByYTRm4hxPfAZcJhMuEwmXCYTNzVocx0TRY6lOTpZ8ezfJfIQz1mDBYO0tji6Q==
apple-push KLUv/QQAtQIAJARNUlMBAAIBAAAKAIgAAtVVVABqqqoAK210b2Vjbi4uZXNsbnBkcGFhay5haC5zbXVvcGMuLitlbHBwYS1oc3VwLisIAGAICIy7AX3BqpoPWN7FdVourB7S
google-fcm KLUv/QQAVQMA1ARNUlMBAAsC/AAAAAwAEwADBaqqqqoqqqr6qqgAAa8ARG1vYy5lbGdvb2cuNGdra25sbGlhYWd0dGFtbXQtczEyMzQ1Njc4LXRrbGF0bQwAgAhAcEAuYBy4hmtUBQX0BatqPmB5F9dpAZt1wrQ=
bosh KLUv/QQARQMAVAVNUlMBAAQBC4ZAQAACVVCqAGuqqtVVVVUAO21vYy5kcHR3aXVjZy1vZWV5cm50ZWduY2stb2VlaGNubHMtbmdiZW9uLm1jaStvZXNobS4ubysraC4rBwBgPO4QNAbE1yTGQhiZewPU9qcI
perplexity KLUv/QQAXQQAIggeJJBRHDOomUMeB14HFLyXQtRkqO5EAgzDkH+3VrgvUEsMnomVAQpbvVnfPirCplcv42MNe1NIOQdxopoxKq/25tqQOjurdRmrZ2GKu/T14247cg9j9Bi2VdlIZgL8F1JmZgY85JFZYP6fMlBcDIiUkBwEhBRwNBgBBgCBPIYiDWbemiRYyCVzWsBdod8=
whatsapp KLUv/QQArQQAckkfI6AxCcxKikoxk1TUkOnl9CkTIJOUUtI4S3yxjhpkYSGSINIH6ZRJOlmmnxunn3rs+am8cuqpe79X38Xt9+sWd4xb96R3nu6aqF59VWZd+lTd2Fczlpq9ytKclRrbFqOkhoqBxUBERAEPQsjxPAZYQIBHCaABEUEBAZEE4hAJAGAOOAyaxgmicwwIVZMAC7lkTgt/ESqR
zoom KLUv/QQADQIA9AJNUlMBAAYVhgABAauqqqqqVVQcbXNvdWMuLm1tdm9vb29vZ3p6bS4ubysrb3ouKwYAMzPSSbhyoyYBFnLJnBaaUyUu
RULESETS
}


# ───────────────────────────── источники нод ─────────────────────────────
# /etc/qcascade/sources.json (600):
#   {"v":1,"sources":[{"name":"MSK","type":"sub","url":"https://…","enabled":true,"prefix":"","meta":{…}},
#                     {"name":"FI-WG","type":"wg","conf":"[Interface]…","enabled":true,"meta":{…}}]}
# sub — Clash/Mihomo-подписка → proxy-provider; wg — WireGuard/AmneziaWG-конфиг → прокси mihomo.
# meta — данные QTerm (панель, клиент, инбаунды); скрипт их не трогает.
src_json() { if [ -s "$SOURCES" ]; then cat "$SOURCES"; else echo '{"v":1,"sources":[]}'; fi; }

SRC_JQ_VALIDATE='
def okname: type=="string" and test("^[A-Za-z0-9._-]{1,32}$");
if (type != "object") or ((.sources|type) != "array") then error("нужен объект {\"sources\":[…]}") else . end
| .sources |= map(
    if (.name|okname|not) then error("имя источника — латиница, цифры, . _ - (до 32 знаков): \(.name|tostring)") else . end
    | if .type == "sub" then
        (if ((.url // "")|type) != "string" or ((.url // "")|test("^https?://")|not) then error("\(.name): нужна http(s)-ссылка подписки") else . end)
      elif .type == "wg" then
        (if ((.conf // "")|test("\\[peer\\]"; "i")|not) then error("\(.name): нужен конфиг WireGuard с разделом [Peer]") else . end)
      else error("\(.name): тип \(.type|tostring) — бывает sub или wg") end
    | .enabled = (if .enabled == false then false else true end)
    | .prefix = (.prefix // "")
    | if (.prefix|test("^[A-Za-z0-9._-]{0,16}$")|not) then error("\(.name): префикс — латиница, цифры, . _ - (до 16)") else . end)
| if ([.sources[].name]|length) != ([.sources[].name]|unique|length) then error("имена источников повторяются") else . end
| .v = 1'

src_write() { # stdin JSON → проверка → /etc/qcascade/sources.json
  local tmp out
  install -d -m 755 "$QC_ETC"
  tmp=$(mktemp "$QC_ETC/.src.XXXX"); CLEAN+=("$tmp")
  cat > "$tmp"
  out=$(jq "$SRC_JQ_VALIDATE" "$tmp" 2>&1) || die "источники не приняты: $(printf '%s' "$out" | sed -E 's/^jq: error( \(at [^)]*\))?: //' | head -3)"
  printf '%s\n' "$out" > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$SOURCES"
}

# v1 → v2: одна подписка QC_SUB_URL становится источником SUB (кэш провайдера переезжает)
migrate_sources() {
  [ -n "${QC_SUB_URL:-}" ] || return 0
  if [ -s "$SOURCES" ]; then
    # старый QTerm прислал QC_SUB_URL — обновить/добавить источник SUB, остальные не трогать
    src_json | jq --arg u "$QC_SUB_URL" '
      if any(.sources[]; .name == "SUB") then .sources |= map(if .name == "SUB" then .url = $u | .type = "sub" else . end)
      else .sources += [{name:"SUB", type:"sub", url:$u, enabled:true, prefix:""}] end' | src_write
  else
    jq -n --arg u "$QC_SUB_URL" '{v:1, sources:[{name:"SUB", type:"sub", url:$u, enabled:true, prefix:""}]}' | src_write
  fi
  if [ -s "$QC_HOME/providers/sub.yaml" ] && [ ! -e "$PROV_DIR/SUB.yaml" ]; then
    cp -p "$QC_HOME/providers/sub.yaml" "$PROV_DIR/SUB.yaml" 2>/dev/null || true
  fi
  QC_SUB_URL=""
  save_env
}

fetch_url() { # fetch_url <url> <куда> → 0 / сообщение об ошибке в stdout
  local url=$1 out=$2 code
  code=$(curl -sSL --max-time 40 -A "clash.meta/mihomo" -o "$out" -w '%{http_code}' "$url" 2>/dev/null) || { echo "нет связи с адресом подписки"; return 1; }
  [ "$code" = 200 ] || { echo "HTTP $code"; return 1; }
  grep -qE '^proxies:' "$out" || { echo "это не Clash/Mihomo-подписка (нет proxies:) — в 3x-ui нужна ссылка Clash/Mihomo"; return 1; }
}

# имена прокси из Clash-YAML (блочный стиль, ключи в любом порядке)
sub_names() {
  awk -v q="'" '
  function unq(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s)
    if (substr(s,1,1)==q && substr(s,length(s),1)==q) { s=substr(s,2,length(s)-2); gsub(q q,q,s) }
    else if (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") { s=substr(s,2,length(s)-2) }
    else sub(/[ \t]+#.*$/,"",s)
    return s }
  /^[^ \t#-]/ { sec=($0 ~ /^proxies:[ \t]*$/); lvl=-1; next }
  !sec { next }
  { if (match($0,/^[ \t]*- /)) { if (lvl<0) lvl=RLENGTH; if (RLENGTH!=lvl) next; r=substr($0,RLENGTH+1) }
    else { if (lvl<0) next; match($0,/^[ \t]*/); if (RLENGTH!=lvl) next; r=substr($0,RLENGTH+1) }
    if (r ~ /^name:/) { sub(/^name:/,"",r); print unq(r) } }' "$1"
}

# WireGuard / AmneziaWG (.conf) → прокси mihomo (YAML с отступом элемента списка proxies:)
# AWG: Jc/Jmin/Jmax/S1-S4/H1-H4 (числа или диапазоны)/I1-I5; 3.x — HeaderProtectionKey, RandomTrailers… (version: 3)
wg_yaml() { # wg_yaml <имя> <conf>; ошибки — в stderr, код 1
  awk -v name="$1" -v q="'" '
  function trim(s){ sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
  function qs(s){ gsub(q, q q, s); return q s q }
  function norm(k){ k=tolower(k); gsub(/[_ \t-]/,"",k); return k }
  function isint(v){ return v ~ /^[0-9]+$/ }
  BEGIN { npeer=0; sec="" }
  /^[ \t]*([#;]|$)/ { next }
  /^[ \t]*\[/ { s=tolower($0); gsub(/[][ \t\r]/,"",s); sec=s; if (sec=="peer") npeer++; next }
  index($0,"=") {
    i=index($0,"="); k=norm(substr($0,1,i-1)); v=trim(substr($0,i+1))
    if (sec=="interface") { if (!(k in I)) order[++no]=k; I[k]=v }
    else if (sec=="peer" && npeer==1) P[k]=v
    next }
  END {
    if (I["privatekey"]=="")  { print "нет PrivateKey в [Interface]" > "/dev/stderr"; exit 1 }
    if (P["publickey"]=="")   { print "нет PublicKey в [Peer]" > "/dev/stderr"; exit 1 }
    ep=P["endpoint"]
    if (ep=="") { print "нет Endpoint в [Peer]" > "/dev/stderr"; exit 1 }
    if (substr(ep,1,1)=="[") { j=index(ep,"]"); host=substr(ep,2,j-2); port=substr(ep,j+2) }
    else { j=0; for (k2=length(ep); k2>0; k2--) if (substr(ep,k2,1)==":") { j=k2; break }
           host=substr(ep,1,j-1); port=substr(ep,j+1) }
    if (host=="" || !isint(port)) { print "Endpoint не в виде адрес:порт — " ep > "/dev/stderr"; exit 1 }
    n=split(I["address"], a, /[ \t]*,[ \t]*/); ip4=""; ip6=""
    for (k2=1; k2<=n; k2++) { x=trim(a[k2]); if (x=="") continue
      if (x ~ /:/) { if (ip6=="") ip6=x } else { if (ip4=="") ip4=x } }
    if (ip4=="" && ip6=="") { print "нет Address в [Interface]" > "/dev/stderr"; exit 1 }
    print "  - name: " qs(name)
    print "    type: wireguard"
    print "    server: " qs(host)
    print "    port: " port
    if (ip4!="") print "    ip: " qs(ip4)
    if (ip6!="") print "    ipv6: " qs(ip6)
    print "    private-key: " qs(I["privatekey"])
    print "    public-key: " qs(P["publickey"])
    if (P["presharedkey"]!="") print "    pre-shared-key: " qs(P["presharedkey"])
    al=P["allowedips"]; if (al=="") al="0.0.0.0/0"
    n=split(al, b, /[ \t]*,[ \t]*/); line=""
    for (k2=1; k2<=n; k2++) { x=trim(b[k2]); if (x!="") line=line (line==""?"":", ") qs(x) }
    print "    allowed-ips: [" line "]"
    print "    udp: true"
    if (isint(I["mtu"])) print "    mtu: " I["mtu"]
    if (isint(P["persistentkeepalive"])) print "    persistent-keepalive: " P["persistentkeepalive"]
    split("jc jmin jmax s1 s2 s3 s4 itime", ints, " ")
    split("h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3", strs, " ")
    v3["headerprotectionkey"]="header-protection-key"; v3["contentpaddingaddition"]="content-padding-addition"
    v3["rekeyaftertime"]="rekey-after-time"; v3["rekeytimeout"]="rekey-timeout"; v3["rejectaftertime"]="reject-after-time"
    v3["keepalivetimeout"]="keepalive-timeout"; v3["maxhandshakeattempts"]="max-handshake-attempts"
    bools["randomtrailers"]="random-trailers"; bools["disablecookies"]="disable-cookies"
    known="privatekey address dns mtu listenport fwmark table preup postup predown postdown saveconfig version"
    nk=split(known, kn, " "); for (k2=1; k2<=nk; k2++) isknown[kn[k2]]=1
    for (k2 in ints) isknown[ints[k2]]=1
    for (k2 in strs) isknown[strs[k2]]=1
    for (k2 in v3) isknown[k2]=1
    for (k2 in bools) isknown[k2]=1
    awg=""; ver=""
    for (k2=1; k2<=8; k2++) { k=ints[k2]; if (k in I) { if (!isint(I[k])) { print k ": не число — " I[k] > "/dev/stderr"; exit 1 }
      awg=awg "      " k ": " I[k] "\n" } }
    for (k2=1; k2<=12; k2++) { k=strs[k2]; if ((k in I) && I[k]!="") awg=awg "      " k ": " qs(I[k]) "\n" }
    for (k in v3) if ((k in I) && I[k]!="") { awg=awg "      " v3[k] ": " qs(I[k]) "\n"; ver="3" }
    for (k in bools) if (k in I) { b2=tolower(I[k]); if (b2 ~ /^(1|true|yes|on)$/) { awg=awg "      " bools[k] ": true\n"; ver="3" } }
    if (("version" in I) && isint(I["version"])) ver=I["version"]
    if (awg!="") {
      print "    amnezia-wg-option:"
      if (ver!="") print "      version: " ver
      printf "%s", awg
    }
    unk=""; for (k2=1; k2<=no; k2++) if (!(order[k2] in isknown)) unk=unk " " order[k2]
    if (unk!="") print "# qcascade: неизвестные ключи [Interface]:" unk > "/dev/stderr"
  }' "$2"
}

# ───────────────────────────── сборка конфига ─────────────────────────────
yq1() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }   # YAML single-quoted
rx_esc() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/]/\\&/g'; }

# Готовит источники в каталоге $1: src.tsv (имя, тип, префикс, файл) и srcstate.jsonl для status.
# Подписки качаются заново; не скачалась — берётся прошлая копия (если есть), ошибка видна в status.
src_prepare() {
  local d=$1 name type enabled prefix url f tmp err cached nodes wgerr
  : > "$d/src.tsv"; : > "$d/srcstate.jsonl"
  install -d -m 750 "$PROV_DIR"
  chown qcascade:qcascade "$PROV_DIR" 2>/dev/null || true
  # разделитель \x1f, не табуляция: пустой префикс иначе «съедается» и поля съезжают
  while IFS=$'\x1f' read -r name type enabled prefix url; do
    [ -n "$name" ] || continue
    err=""; cached=false; nodes=0
    if [ "$enabled" != true ]; then
      jq -nc --arg n "$name" --arg t "$type" '{name:$n, type:$t, enabled:false, nodes:0, error:"", cached:false}' >> "$d/srcstate.jsonl"
      continue
    fi
    if [ "$type" = sub ]; then
      f="$PROV_DIR/$name.yaml"
      tmp=$(mktemp "$PROV_DIR/.dl.XXXX"); CLEAN+=("$tmp")
      if err=$(fetch_url "$url" "$tmp"); then
        install -m 640 "$tmp" "$f"; chown qcascade:qcascade "$f" 2>/dev/null || true
        err=""
      elif [ -s "$f" ]; then
        err="$err — взята прошлая копия"; cached=true
      else
        jq -nc --arg n "$name" --arg e "$err" '{name:"\($n)", type:"sub", enabled:true, nodes:0, error:$e, cached:false}' >> "$d/srcstate.jsonl"
        continue
      fi
      nodes=$(sub_names "$f" | grep -cE '^[A-Za-z0-9._-]+$' || true)
      printf '%s\x1f%s\x1f%s\x1f%s\n' "$name" sub "$prefix" "$f" >> "$d/src.tsv"
    else
      f="$d/wg-$name.conf"
      src_json | jq -r --arg n "$name" '.sources[] | select(.name == $n) | .conf' > "$f"
      if ! wgerr=$(wg_yaml "$name" "$f" 2>&1 >/dev/null); then
        jq -nc --arg n "$name" --arg e "конфиг: $wgerr" '{name:$n, type:"wg", enabled:true, nodes:0, error:$e, cached:false}' >> "$d/srcstate.jsonl"
        continue
      fi
      [ -n "$wgerr" ] && err=${wgerr#\# qcascade: }
      nodes=1
      printf '%s\x1f%s\x1f%s\x1f%s\n' "$name" wg "" "$f" >> "$d/src.tsv"
    fi
    jq -nc --arg n "$name" --arg t "$type" --arg e "$err" --argjson c "$cached" --argjson k "$nodes" \
      '{name:$n, type:$t, enabled:true, nodes:$k, error:$e, cached:$c}' >> "$d/srcstate.jsonl"
  done < <(src_json | jq -r '.sources[] | [.name, .type, (.enabled|tostring), (.prefix // ""), (.url // "")] | join("\u001f")')
}

need_tproxy() { [ "$QC_AWG_MODE" != off ] || [ "$QC_MTP" = on ]; }

# build_config <каталог с src.tsv> <out.yaml> <state.json>
build_config() {
  local d=$1 out=$2 st=$3 name type prefix f n
  : > "$d/nodes.tsv"; : > "$d/wg.yaml"; : > "$d/wgnames"; : > "$d/providers.yaml"
  # ── узлы: из подписок (с префиксом) и WG-прокси ──
  while IFS=$'\x1f' read -r name type prefix f; do
    if [ "$type" = sub ]; then
      sub_names "$f" | awk 'NF' | awk -v p="$prefix" -v s="@$name" '!seen[$0]++ { print p $0 "\t" s }' >> "$d/nodes.tsv"
      {
        # имя провайдера с @: mihomo заводит провайдер на каждую группу под её именем — не пересечься с группами
        echo "  $(yq1 "@$name"):"
        echo "    type: http"
        echo "    url: $(yq1 "$(src_json | jq -r --arg n "$name" '.sources[] | select(.name == $n) | .url')")"
        echo "    path: ./providers/$name.yaml"
        echo "    interval: 3600"
        echo "    proxy: DIRECT"
        echo "    health-check:"
        echo "      enable: true"
        echo "      url: https://www.gstatic.com/generate_204"
        echo "      interval: 300"
        echo "      timeout: 3000"
        echo "      lazy: true"
        if [ -n "$prefix" ]; then
          echo "    override:"
          echo "      additional-prefix: $(yq1 "$prefix")"
        fi
      } >> "$d/providers.yaml"
    else
      wg_yaml "$name" "$f" >> "$d/wg.yaml" 2>/dev/null
      printf '%s\t@wg\n' "$name" >> "$d/nodes.tsv"
      echo "$name" >> "$d/wgnames"
    fi
  done < "$d/src.tsv"
  awk -F'\t' '$1 ~ /^[A-Za-z0-9._-]+$/' "$d/nodes.tsv" > "$d/nodes.ok"
  cut -f1 "$d/nodes.ok" | awk '!seen[$0]++' > "$d/names"
  cut -f1 "$d/nodes.ok" | sort | uniq -d > "$d/dups"
  if [ ! -s "$d/names" ]; then
    err "нет ни одной ноды: источники пустые или не скачались (имена должны быть как инбаунды — шаблон {{INBOUND}})"
    return 1
  fi

  # ── составные группы ──
  awk '!/^[ \t]*(#|$)/ && NF>=3' "$GROUPS_F" > "$d/groups" || true
  awk '{print $1}' "$d/groups" > "$d/gnames"

  # ── резерв: WG-источник или нода, есть в узлах ──
  local reserve=""
  if [ -n "$QC_RESERVE" ]; then
    if grep -qxF -- "$QC_RESERVE" "$d/names" && ! grep -qxF -- "$QC_RESERVE" "$d/gnames"; then reserve=$QC_RESERVE
    else echo "$QC_RESERVE" > "$d/reserve_missing"; fi
  fi
  touch "$d/reserve_missing"

  # имя группы-«сырья» ноды (select по провайдерам): своё имя, а при резерве (кроме самой ноды-резерва)
  # или совпадении с именем составной группы — ~ИМЯ (скрытая); WG-прокси — своё имя
  rawname() {
    if grep -qxF -- "$1" "$d/wgnames" || [ "$1" = "$reserve" ]; then printf '%s' "$1"; return; fi
    if [ -n "$reserve" ] || grep -qxF -- "$1" "$d/gnames"; then printf '~%s' "$1"; else printf '%s' "$1"; fi
  }

  # ── rule-providers: перепись путей, пропуск file-провайдеров без файла ──
  awk -v rsdir="$RSDIR" -v miss="$d/missing" '
    function flush(   i, base, p) {
      if (name == "") return
      if (type == "file") {
        p = path; base = p; sub(/^.*\//, "", base)
        newp = rsdir "/" base
        if (system("test -s \"" newp "\"") != 0) { print name > miss; name=""; n=0; return }
        for (i=1;i<=n;i++) { if (buf[i] ~ /^[ \t]+path:/) { match(buf[i],/^[ \t]+/); buf[i]=substr(buf[i],1,RLENGTH) "path: " newp } }
      } else {
        for (i=1;i<=n;i++) if (buf[i] ~ /^[ \t]+path:[ \t]*["\047]?\/opt\/etc\/mihomo\//) {
          sub(/\/opt\/etc\/mihomo\//, "./", buf[i]) }
      }
      for (i=1;i<=n;i++) print buf[i]
      name=""; n=0
    }
    /^[^ \t#]/ { if (sec) flush(); sec = ($0 ~ /^rule-providers:[ \t]*$/); if (sec) print "rule-providers:"; next }
    !sec { next }
    /^  [^ \t#][^:]*:[ \t]*$/ { flush(); name=$0; sub(/^  /,"",name); sub(/:[ \t]*$/,"",name); type=""; path=""; n=1; buf[1]=$0; next }
    {
      if (name == "") next
      buf[++n]=$0
      if ($0 ~ /^[ \t]+type:/) { t=$0; sub(/^[ \t]+type:[ \t]*/,"",t); gsub(/["\047 \t]/,"",t); type=t }
      if ($0 ~ /^[ \t]+path:/) { t=$0; sub(/^[ \t]+path:[ \t]*/,"",t); gsub(/["\047]/,"",t); sub(/[ \t]+#.*$/,"",t); sub(/[ \t]+$/,"",t); path=t }
    }
    END { if (sec) flush() }' "$RULES" > "$d/rprov"
  touch "$d/missing"

  # ── rules: пропуск правил с отсутствующими rule-set, замена DIRECT, сбор целей ──
  awk -v miss="$d/missing" -v dt="$QC_DIRECT_TARGET" -v tg="$d/targets" '
    BEGIN { while ((getline l < miss) > 0) m[l]=1 }
    /^[^ \t#]/ { sec = ($0 ~ /^rules:[ \t]*$/)
      if (sec) { print "rules:"; print "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve   # qcascade: служебное — проверка готовности mihomo" }
      next }
    !sec { next }
    /^[ \t]*#/ || /^[ \t]*$/ { print; next }
    /^[ \t]*- / {
      line=$0; match(line,/^[ \t]*- [ \t]*/); ind=substr(line,1,RLENGTH); body=substr(line,RLENGTH+1)
      cm=""; if (match(body,/[ \t]+#.*$/)) { cm=substr(body,RSTART); body=substr(body,1,RSTART-1) }
      for (k in m) if (index(body,"RULE-SET," k ",")==1 || index(body,"(RULE-SET," k ")")>0) {
        sp=ind; sub(/-.*$/,"",sp); print sp "# [qcascade: нет rule-set " k "] - " body; next }
      nf=split(body,a,","); ti=nf; if (a[nf] ~ /^(no-resolve|src)$/) ti=nf-1
      t=a[ti]; gsub(/[ \t"\047]/,"",t)
      if (t=="DIRECT" && dt!="DIRECT") { a[ti]=dt; t=dt; body=a[1]; for (i=2;i<=nf;i++) body=body "," a[i] }
      print t > tg
      print ind body cm; next }
    { print }' "$RULES" > "$d/rules"
  touch "$d/targets"

  local hc_lines='    url: https://www.gstatic.com/generate_204'
  # ── proxy-groups ──
  {
    echo "proxy-groups:"
    # «сырьё» по нодам из подписок; при резерве поверх — одноимённая fallback-обёртка [~ИМЯ, резерв]
    local x raw provs
    while IFS= read -r x; do
      grep -qxF -- "$x" "$d/wgnames" && continue
      raw=$(rawname "$x")
      provs=$(awk -F'\t' -v x="$x" '$1==x && $2!="@wg" {print $2}' "$d/nodes.ok" | awk '!s[$0]++' | while IFS= read -r p; do printf '%s, ' "$(yq1 "$p")"; done)
      provs=${provs%, }
      # префикс источника уже в имени — фильтр по полному имени
      printf '  - { name: %s, type: select, use: [%s], filter: %s%s }\n' "$(yq1 "$raw")" "$provs" "$(yq1 "^$(rx_esc "$x")\$")" \
        "$( [ "$raw" != "$x" ] && echo ", hidden: true" )"
      if [ -n "$reserve" ] && [ "$x" != "$reserve" ] && ! grep -qxF -- "$x" "$d/gnames"; then
        printf '  - { name: %s, type: fallback, proxies: [%s, %s], url: %s, interval: 60, timeout: 3000, lazy: false }\n' \
          "$(yq1 "$x")" "$(yq1 "$raw")" "$(yq1 "$reserve")" "'https://www.gstatic.com/generate_204'"
      fi
    done < "$d/names"
    # составные
    local gname gtype gint members m res
    while read -r gname gtype gint members; do
      res=()
      for m in $members; do
        [ "$m" = "$gname" ] && grep -qxF -- "$m" "$d/gnames" && ! grep -qxF -- "$m" "$d/names" && continue
        if grep -qxF -- "$m" "$d/names"; then res+=("$(rawname "$m")")
        elif grep -qxF -- "$m" "$d/gnames"; then [ "$m" = "$gname" ] || res+=("$m")
        else echo "$gname: $m" >> "$d/skipped"; fi
      done
      if [ -n "$reserve" ]; then
        local has=0 r; for r in "${res[@]}"; do [ "$r" = "$reserve" ] && has=1; done
        [ $has = 1 ] || res+=("$reserve")
      fi
      echo "  - name: $(yq1 "$gname")"
      echo "    type: $gtype"
      if [ ${#res[@]} -gt 0 ]; then
        printf '    proxies: ['; local first=1
        for m in "${res[@]}"; do [ $first = 1 ] || printf ', '; printf '%s' "$(yq1 "$m")"; first=0; done
        printf ']\n'
        [ ${#res[@]} -eq 1 ] && [ -n "$reserve" ] && [ "${res[0]}" = "$reserve" ] && echo "$gname" >> "$d/empty"
      else
        echo "    proxies: [DIRECT]"
        echo "$gname" >> "$d/empty"
      fi
      if [ "$gtype" != select ]; then
        echo "$hc_lines"
        echo "    interval: ${gint:-60}"
        echo "    timeout: 3000"
        echo "    lazy: false"
      fi
    done < "$d/groups"
    # заглушки для целей правил, которых нет нигде: при резерве — в резерв, иначе DIRECT
    sort -u "$d/targets" | while IFS= read -r t; do
      case "$t" in DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE|GLOBAL|"") continue ;; esac
      grep -qxF -- "$t" "$d/gnames" && continue
      grep -qxF -- "$t" "$d/names" && continue
      if [ -n "$reserve" ]; then echo "  - { name: $(yq1 "$t"), type: select, proxies: [$(yq1 "$reserve")] }"
      else echo "  - { name: $(yq1 "$t"), type: select, proxies: [DIRECT] }"; fi
      echo "$t" >> "$d/placeholders"
    done
  } > "$d/pg"
  touch "$d/empty" "$d/placeholders" "$d/skipped"

  # ── итоговый конфиг ──
  {
    cat <<EOF
# Сгенерировано qcascade $VERSION — не править руками.
# Источники: $SOURCES   Правила: $RULES   Группы: $GROUPS_F   Применить: qcascade apply
mixed-port: $QC_PORT
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: off
external-controller: $QC_API
secret: $(yq1 "$QC_SECRET")
external-ui: ui
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
profile:
  store-selected: true
dns:
  enable: false
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
EOF
    if need_tproxy; then
      echo ""
      echo "# перехват AWG-интерфейсов и MTProto (nftables tproxy → сюда; правила ставит qcascade nf up)"
      echo "listeners:"
      echo "  - { name: qc-tproxy, type: tproxy, port: $QC_TPROXY_PORT, listen: 127.0.0.1, udp: true }"
    fi
    if [ -s "$d/wg.yaml" ]; then echo ""; echo "proxies:"; cat "$d/wg.yaml"; fi
    if [ -s "$d/providers.yaml" ]; then echo ""; echo "proxy-providers:"; cat "$d/providers.yaml"; fi
    echo ""
    cat "$d/pg"; echo
    cat "$d/rprov"; echo
    cat "$d/rules"
  } > "$out"

  jq -n --rawfile names "$d/names" --rawfile missing "$d/missing" --rawfile ph "$d/placeholders" \
        --rawfile empty "$d/empty" --rawfile skipped "$d/skipped" --rawfile dups "$d/dups" \
        --rawfile rmiss "$d/reserve_missing" --slurpfile src "$d/srcstate.jsonl" \
        --arg reserve "$reserve" --arg ts "$(date -Is)" '
    def lines: split("\n")|map(select(length>0));
    {built:$ts, nodes:($names|lines), sources:$src, duplicates:($dups|lines),
     reserve:$reserve, reserveMissing:($rmiss|lines),
     missingRulesets:($missing|lines), placeholders:($ph|lines), emptyGroups:($empty|lines),
     skippedMembers:($skipped|lines)}' > "$st"
}

mh_test() { # mh_test <config>
  SAFE_PATHS=$QC_ETC "$QC_BIN" -t -d "$QC_HOME" -f "$1" 2>&1 | grep -vE 'level=info' | tail -5
  SAFE_PATHS=$QC_ETC "$QC_BIN" -t -d "$QC_HOME" -f "$1" >/dev/null 2>&1
}
api() { curl -fsS --max-time "${2:-5}" -H "Authorization: Bearer $QC_SECRET" "http://$QC_API$1"; }
# mihomo готов: API поднимается раньше, чем загрузятся провайдеры, а до их загрузки соединения сбрасываются —
# поэтому проверяем сам туннель: запрос к API через mixed-порт (правило 127.0.0.0/8 → DIRECT стоит первым)
mh_ready() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --noproxy '' -x "http://127.0.0.1:$QC_PORT" \
         -H "Authorization: Bearer $QC_SECRET" "http://127.0.0.1:${QC_API##*:}/version" 2>/dev/null) || true
  [ "$code" = 200 ]   # 502 — это mihomo сам: туннель ещё не принимает
}
mh_healthy() { # ждём API и туннель до N сек
  local n=${1:-60} i
  for ((i=0; i<n; i++)); do
    systemctl is-active -q "$SVC" || { sleep 1; continue; }
    api /version >/dev/null 2>&1 && mh_ready && return 0
    sleep 1
  done
  return 1
}

# ───────────────────────────── apply ─────────────────────────────
cmd_apply() {
  local if_changed=0 a
  for a in "$@"; do case $a in --if-changed) if_changed=1 ;; --quiet|-q) QUIET=1 ;; esac; done
  need_root; load_env; defaults
  [ -x "$QC_BIN" ] || die "нет ядра — сначала qcascade install"
  install -d -m 755 "$QC_ETC" "$RSDIR"; install -d -m 750 -o qcascade -g qcascade "$QC_HOME" "$PROV_DIR"
  write_default_rules; write_default_groups; install_bundled_rulesets
  migrate_sources

  local d new st_new
  d=$(mktemp -d "$QC_HOME/.build.XXXX"); CLEAN+=("$d")
  new="$d/config.yaml"; st_new="$d/state.json"
  if [ "$(src_json | jq '[.sources[] | select(.enabled != false)] | length')" = 0 ]; then
    [ "$if_changed" = 1 ] && { warn "источников нет — конфиг не трогаю"; return 0; }
    err "нет ни одного источника нод — добавь подписку или WireGuard (QTerm → Каскад → Источники)"
    return 1
  fi
  src_prepare "$d"
  build_config "$d" "$new" "$st_new" || return 1

  if [ "$if_changed" = 1 ] && [ -f "$CFG" ] && cmp -s "$new" "$CFG" && systemctl is-active -q "$SVC"; then
    install -m 644 "$st_new" "$STATE"
    nf_sync
    say "без изменений"; return 0
  fi

  local out
  if ! out=$(mh_test "$new"); then
    install -m 600 "$new" "$CFG.bad"
    err "конфиг с ошибкой — НЕ применён, работает прежний (сохранён в $CFG.bad):"
    printf '       %s\n' "$out" >&2
    return 1
  fi

  [ -f "$CFG" ] && cp -f "$CFG" "$CFG.prev"
  install -m 640 -o root -g qcascade "$new" "$CFG"
  install -m 644 "$st_new" "$STATE"
  systemctl restart "$SVC"
  if mh_healthy 90; then
    ok "mihomo применил конфиг ($(jq '.nodes|length' "$STATE") нод из $(jq '[.sources[]|select(.enabled and .nodes>0)]|length' "$STATE") источников)"
  else
    err "mihomo не поднялся с новым конфигом — откатываю"
    install -m 600 "$CFG" "$CFG.bad"
    if [ -f "$CFG.prev" ]; then install -m 640 -o root -g qcascade "$CFG.prev" "$CFG"; systemctl restart "$SVC"; mh_healthy 60 || err "и прежний не поднялся: journalctl -u $SVC"; fi
    journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/       /' >&2 || true
    return 1
  fi
  report_state
}

report_state() {
  [ -f "$STATE" ] || return 0
  local x
  x=$(jq -r '[.sources[]? | select(.error != "") | "\(.name): \(.error)"] | join("; ")' "$STATE"); [ -n "$x" ] && warn "источники: $x"
  x=$(jq -r '(.duplicates // []) | join(", ")' "$STATE"); [ -n "$x" ] && warn "одинаковые имена нод в разных источниках: $x — задай источнику префикс"
  x=$(jq -r '(.reserveMissing // []) | join(", ")' "$STATE"); [ -n "$x" ] && warn "резерв «$x» не найден среди нод — резерв выключен"
  x=$(jq -r '.missingRulesets|join(", ")' "$STATE"); [ -n "$x" ] && warn "нет файлов rule-set: $x — их правила пропущены (положи .mrs в $RSDIR и qcascade apply)"
  x=$(jq -r '.placeholders|join(", ")' "$STATE");    [ -n "$x" ] && warn "правила ссылаются на то, чего нет в источниках: $x → $( [ -n "$(jq -r '.reserve' "$STATE")" ] && echo резерв || echo DIRECT )"
  x=$(jq -r '.emptyGroups|join(", ")' "$STATE");     [ -n "$x" ] && warn "группы без единой ноды: $x → $( [ -n "$(jq -r '.reserve' "$STATE")" ] && echo резерв || echo DIRECT )"
  return 0
}

# ───────────────────────────── сетевой перехват (nftables tproxy) ─────────────────────────────
# AWG-клиенты awg-panel (wg0, awg1…): TCP и UDP во внешний мир → mihomo (локальное — мимо).
# MTProto: docker (mtg, teleproxy) и процессы пользователей telemt / mtproxy (WEB) — TCP к подсетям Telegram → mihomo,
# дальше по правилам (Telegram → группа TG). Свой трафик mihomo (пользователь qcascade) не трогается.
TG_BUILTIN="91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 149.154.160.0/20 185.76.151.0/24"
PRIV4="0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3"

tg_cidrs() { # подсети Telegram: свежий список core.telegram.org (кэш) + встроенный
  local f tmp
  tmp=$(mktemp); CLEAN+=("$tmp")
  if [ ! -s "$TG_CIDR" ] || [ -n "$(find "$TG_CIDR" -mtime +7 2>/dev/null)" ]; then
    if curl -fsS --max-time 8 https://core.telegram.org/resources/cidr.txt -o "$tmp" 2>/dev/null && grep -qE '^[0-9]+\.' "$tmp"; then
      install -m 644 "$tmp" "$TG_CIDR"
    fi
  fi
  { printf '%s\n' $TG_BUILTIN; if [ -s "$TG_CIDR" ]; then grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$TG_CIDR" || true; fi; } \
    | sort -u | paste -sd, - | sed 's/,/, /g'
}

awg_ifaces() { # интерфейсы WireGuard/AmneziaWG на хосте (имя<TAB>адрес)
  local n
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | while IFS= read -r n; do
    case $n in wg*|awg*) ;; *) ip -d link show "$n" 2>/dev/null | grep -qE '\b(wireguard|amneziawg)\b' || continue ;; esac
    printf '%s\t%s\n' "$n" "$(ip -o -4 addr show dev "$n" 2>/dev/null | awk '{print $4}' | head -1)"
  done
}

mtp_uids() { # uid существующих пользователей MTProto через запятую (нет таких — пусто)
  local u out=""
  for u in $QC_MTP_USERS; do id -u "$u" >/dev/null 2>&1 && out+="$(id -u "$u"), "; done
  printf '%s' "${out%, }"
}

nf_rules() { # nf_rules [no6] — таблица nft под текущие настройки (пусто — перехват не нужен)
  local tp=$QC_TPROXY_PORT m=$NF_MARK body="" src="" uids tg i v6=1
  { [ -d /proc/sys/net/ipv6 ] && [ "${1:-}" != no6 ]; } || v6=0
  local -a ifs=()
  if [ "$QC_AWG_MODE" = all ]; then ifs=("wg*" "awg*")
  elif [ "$QC_AWG_MODE" = list ]; then read -r -a ifs <<< "$QC_AWG_IFACES"; fi
  if [ -n "$QC_AWG_SRC" ]; then
    local -a srcarr=(); read -r -a srcarr <<< "$QC_AWG_SRC"
    src="ip saddr { $(printf '%s, ' "${srcarr[@]}" | sed 's/, $//') } "
  fi
  local fwd=""
  for i in "${ifs[@]}"; do
    [[ "$i" =~ ^[A-Za-z0-9._*-]+$ ]] || continue
    body+="    iifname \"$i\" ${src}ip daddr != @priv4 fib daddr type != local meta l4proto { tcp, udp } meta mark set $m tproxy ip to 127.0.0.1:$tp accept"$'\n'
    # IPv6 клиентов мимо каскада не пускаем: отказ → приложения сразу уходят на IPv4, а он идёт в каскад
    if [ -z "$src" ] && [ $v6 = 1 ]; then
      fwd+="    iifname \"$i\" ip6 daddr != { fc00::/7, fe80::/10, ff00::/8 } meta l4proto tcp reject with tcp reset"$'\n'
      fwd+="    iifname \"$i\" ip6 daddr != { fc00::/7, fe80::/10, ff00::/8 } reject with icmpx type admin-prohibited"$'\n'
    fi
  done
  local out=""
  if [ "$QC_MTP" = on ]; then
    tg=$(tg_cidrs)
    body+="    iifname \"docker0\" ip daddr @tg4 meta l4proto tcp meta mark set $m tproxy ip to 127.0.0.1:$tp accept"$'\n'
    body+="    iifname \"br-*\" ip daddr @tg4 meta l4proto tcp meta mark set $m tproxy ip to 127.0.0.1:$tp accept"$'\n'
    uids=$(mtp_uids)
    if [ -n "$uids" ]; then
      # IPv6 у MTProto-процессов — отказ (перехват только IPv4): уходят на IPv4 → в каскад
      out="  chain out {
    type route hook output priority mangle; policy accept;
    meta skuid { $uids } ip daddr @tg4 meta l4proto tcp meta mark set $m
  }"
      [ $v6 = 1 ] && out+="
  chain v6out {
    type filter hook output priority filter; policy accept;
    meta skuid { $uids } ip6 daddr != { ::1, fc00::/7, fe80::/10 } meta l4proto tcp reject with tcp reset
  }"
    fi
  fi
  [ -n "$body" ] || return 0
  cat <<EOF
table inet $NF_NAME {
  set priv4 { type ipv4_addr; flags interval; elements = { $PRIV4 } }
$( [ "$QC_MTP" = on ] && echo "  set tg4 { type ipv4_addr; flags interval; auto-merge; elements = { $tg } }" )
  chain pre {
    type filter hook prerouting priority mangle; policy accept;
    iif "lo" meta mark $m meta l4proto tcp tproxy ip to 127.0.0.1:$tp accept
$body  }
$( [ -n "$fwd" ] && printf '  chain v6block {\n    type filter hook forward priority filter; policy accept;\n%s  }' "$fwd" )
$out
}
EOF
}

ipt() { command -v iptables >/dev/null 2>&1 && iptables -w "$@"; }

nf_down() {
  rm -f "$NF_SAVED"
  nft delete table inet "$NF_NAME" 2>/dev/null || true
  while ip rule del fwmark "$NF_MARK" lookup "$NF_TABLE" 2>/dev/null; do :; done
  ip route flush table "$NF_TABLE" 2>/dev/null || true
  while ipt -D INPUT -m mark --mark "$NF_MARK" -m comment --comment "$NF_NAME" -j ACCEPT 2>/dev/null; do :; done
}

nf_up() { # nf_up [--wait]: ставит правила, если mihomo слушает tproxy-порт
  local rules full wait=0 i
  [ "${1:-}" = --wait ] && wait=1
  rules=$(nf_rules); full=$rules
  nf_down
  [ -n "$rules" ] || return 0
  if [ $wait = 1 ]; then
    # mihomo открывает порты раньше, чем загрузит провайдеры, и до этого сбрасывает соединения —
    # ждём готовности туннеля (первая загрузка rule-set'ов бывает долгой); не дождались — ставим всё равно
    for ((i=0; i<160; i++)); do mh_ready && break; sleep 0.5; done
    mh_ready || warn "mihomo ещё грузит провайдеров — перехват ставлю, соединения пойдут, когда догрузит"
  fi
  if ! ss -Hltn "( sport = :$QC_TPROXY_PORT )" 2>/dev/null | grep -q .; then
    warn "mihomo не слушает tproxy-порт $QC_TPROXY_PORT — перехват AWG/MTProto не включаю (трафик пойдёт напрямую)"
    return 0
  fi
  if ! printf '%s\n' "$rules" | nft -f - 2>"$QC_HOME/nf.err"; then
    # ядро без IPv6-reject и т.п. — ставим без IPv6-части
    rules=$(nf_rules no6)
    printf '%s\n' "$rules" | nft -f - || { err "nftables не принял правила перехвата: $(head -3 "$QC_HOME/nf.err")"; return 0; }
    warn "IPv6-часть перехвата не принята ядром — IPv6 клиентов не перекрыт"
  fi
  printf '%s\n' "$full" > "$NF_SAVED" 2>/dev/null || true
  ip rule add fwmark "$NF_MARK" lookup "$NF_TABLE" pref "$NF_PREF" 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table "$NF_TABLE"
  # UFW и прочие INPUT DROP режут перехваченные пакеты (адрес назначения — чужой) — пропускаем по метке
  ipt -C INPUT -m mark --mark "$NF_MARK" -m comment --comment "$NF_NAME" -j ACCEPT 2>/dev/null \
    || ipt -I INPUT 1 -m mark --mark "$NF_MARK" -m comment --comment "$NF_NAME" -j ACCEPT 2>/dev/null || true
  return 0
}

nf_active() { nft list table inet "$NF_NAME" >/dev/null 2>&1; }

nf_sync() { # таймер: появились пользователи MTProto, обновились подсети Telegram — переставить перехват
  systemctl is-active -q "$SVC" || return 0
  local want
  want=$(nf_rules)
  if [ -n "$want" ]; then
    if ! nf_active || [ "$want" != "$(cat "$NF_SAVED" 2>/dev/null)" ]; then nf_up; fi
  elif nf_active; then nf_down; fi
  return 0
}

cmd_nf() {
  need_root; load_env; defaults
  case ${1:-status} in
    up)     nf_up "${2:-}" ;;
    sync)   nf_sync ;;
    down)   nf_down ;;
    rules)  nf_rules ;;
    status) if nf_active; then echo "перехват: включён"; nft list table inet "$NF_NAME"; else echo "перехват: выключен"; fi ;;
    *) die "qcascade nf up|down|sync|status|rules" ;;
  esac
}

# ───────────────────────────── что есть на сервере ─────────────────────────────
detect_json() {
  local xui=false ib='[]' em='[]' awg='[]' users='[]' ctr='[]' docker=false
  if systemctl cat x-ui >/dev/null 2>&1; then
    xui=true
    ib=$( (xray_inbounds 2>/dev/null || true) | jq -R 'split("|") | {tag:.[0], protocol:.[1], remark:(.[2] // "")}' | jq -s .)
    em=$( (xray_emails 2>/dev/null || true) | jq -R . | jq -s .)
  fi
  awg=$(awg_ifaces | jq -R 'split("\t") | {name:.[0], addr:(.[1] // "")}' | jq -s .)
  local u
  # пользователи MTProto: известные (telemt, mtproxy — WEB) и заданные; в списке — только существующие
  users=$(for u in telemt mtproxy $QC_MTP_USERS; do if id -u "$u" >/dev/null 2>&1; then echo "$u"; fi; done | awk '!s[$0]++' | jq -R . | jq -s .)
  if command -v docker >/dev/null 2>&1; then
    docker=true
    ctr=$( { docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true; } \
          | awk -F'\t' 'tolower($1 $2) ~ /mtg|teleproxy|mtproto|mtproxy/' \
          | jq -R 'split("\t") | {name:.[0], image:(.[1] // "")}' | jq -s .)
  fi
  jq -n --argjson xui "$xui" --argjson ib "$ib" --argjson em "$em" --argjson awg "$awg" \
        --argjson users "$users" --argjson ctr "$ctr" --argjson docker "$docker" \
    '{xui:$xui, inbounds:$ib, emails:$em, awg:$awg, mtp:{users:$users, docker:$docker, containers:$ctr}}'
}
# ───────────────────────────── 3x-ui / xray ─────────────────────────────
xui_env() { systemctl show x-ui -p Environment --value 2>/dev/null || true; }
xui_db() {
  local e f
  e=$(xui_env)
  [[ "$e" =~ XUI_DB_TYPE=(postgres|postgresql|pg) ]] && die "3x-ui на PostgreSQL — правка шаблона через sqlite невозможна"
  f=/etc/x-ui
  [[ "$e" =~ XUI_DB_FOLDER=([^[:space:]]+) ]] && f=${BASH_REMATCH[1]}
  [ -f "$f/x-ui.db" ] || die "не найдена база 3x-ui ($f/x-ui.db)"
  echo "$f/x-ui.db"
}
xray_bin() { ls "$XUI_DIR"/bin/xray-linux-* 2>/dev/null | head -1; }
sql() { sqlite3 -cmd ".timeout 8000" "$@"; }

# дефолтный шаблон 3x-ui v3 (если в базе его ещё нет — панель берёт встроенный)
DEFAULT_TEMPLATE='{"api":{"services":["HandlerService","LoggerService","StatsService","RoutingService"],"tag":"api"},"inbounds":[{"listen":"127.0.0.1","port":62789,"protocol":"tunnel","settings":{"rewriteAddress":"127.0.0.1"},"tag":"api"}],"log":{"access":"none","dnsLog":false,"error":"","loglevel":"warning","maskAddress":""},"metrics":{"listen":"127.0.0.1:11111","tag":"metrics_out"},"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"block","ip":["geoip:private"]},{"action":"allow"}]},"tag":"direct"},{"protocol":"blackhole","settings":{},"tag":"blocked"}],"policy":{"levels":{"0":{"statsUserDownlink":true,"statsUserUplink":true}},"system":{"statsInboundDownlink":true,"statsInboundUplink":true,"statsOutboundDownlink":false,"statsOutboundUplink":false}},"routing":{"domainStrategy":"AsIs","rules":[{"inboundTag":["api"],"outboundTag":"api","type":"field"},{"ip":["geoip:private"],"outboundTag":"blocked","type":"field"},{"outboundTag":"blocked","protocol":["bittorrent"],"type":"field"}]},"stats":{}}'

tpl_get() { # tpl_get <db> → stdout; код 3 если строки нет
  local db=$1 cnt
  cnt=$(sql -readonly "$db" "SELECT count(*) FROM settings WHERE key='xrayTemplateConfig';")
  if [ "$cnt" = 0 ]; then printf '%s' "$DEFAULT_TEMPLATE"; return 3; fi
  sql -readonly "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;"
}
tpl_put() { # tpl_put <db> <file>
  local db=$1 f=$2 cnt
  cnt=$(sql -readonly "$db" "SELECT count(*) FROM settings WHERE key='xrayTemplateConfig';")
  if [ "$cnt" = 0 ]; then
    sql "$db" "INSERT INTO settings(key,value) VALUES('xrayTemplateConfig', CAST(readfile('$f') AS TEXT));"
  else
    sql "$db" "UPDATE settings SET value=CAST(readfile('$f') AS TEXT) WHERE key='xrayTemplateConfig';"
  fi
}
xray_inbounds() { # tag|protocol|remark
  local db; db=$(xui_db)
  sql -readonly -separator '|' "$db" "SELECT tag, protocol, remark FROM inbounds WHERE enable=1 AND (node_id IS NULL OR node_id=0) ORDER BY id;" 2>/dev/null \
  || sql -readonly -separator '|' "$db" "SELECT tag, protocol, remark FROM inbounds WHERE enable=1 ORDER BY id;"
}
xray_emails() {
  local db; db=$(xui_db)
  sql -readonly "$db" "SELECT settings FROM inbounds WHERE enable=1;" 2>/dev/null \
    | jq -r '.clients[]?.email // empty' 2>/dev/null | sort -u
}

# xray_hook on|off — правит шаблон, перезапускает x-ui, проверяет, откатывает
xray_hook() {
  local want=$1 db rc=0 orig new xb ts out rule
  [ -x "$XUI_DIR/x-ui" ] || systemctl cat x-ui >/dev/null 2>&1 || die "3x-ui не найден"
  db=$(xui_db)
  install -d -m 700 "$BK"; ts=$(date +%Y%m%d-%H%M%S)
  sql "$db" ".backup '$BK/x-ui.db.$ts'" || die "не удалось сделать бэкап базы 3x-ui"
  ls -1t "$BK"/x-ui.db.* 2>/dev/null | tail -n +11 | xargs -r rm -f   # храним 10 последних

  orig=$(mktemp --suffix=.json); new=$(mktemp --suffix=.json); CLEAN+=("$orig" "$new")
  tpl_get "$db" > "$orig" || rc=$?
  [ $rc = 0 ] || [ $rc = 3 ] || { rm -f "$orig" "$new"; die "не прочитал шаблон Xray из базы"; }
  jq -e . "$orig" >/dev/null 2>&1 || { rm -f "$orig" "$new"; die "шаблон Xray в базе — невалидный JSON"; }

  if [ "$want" = on ]; then
    case $QC_XRAY_MODE in
      all)      rule='{"type":"field","ruleTag":"qcascade","network":"tcp,udp","outboundTag":"qcascade"}' ;;
      inbounds) rule=$(jq -nc --arg l "$QC_XRAY_LIST" '{type:"field",ruleTag:"qcascade",inboundTag:($l|split(" ")|map(select(length>0))),outboundTag:"qcascade"}') ;;
      users)    rule=$(jq -nc --arg l "$QC_XRAY_LIST" '{type:"field",ruleTag:"qcascade",user:($l|split(" ")|map(select(length>0))),outboundTag:"qcascade"}') ;;
      *) want=off ;;
    esac
  fi
  if [ "$want" = on ]; then
    jq --argjson port "$QC_PORT" --argjson rule "$rule" '
      .outbounds = (((.outbounds // []) | map(select(.tag != "qcascade")))
                    + [{tag:"qcascade",protocol:"socks",settings:{address:"127.0.0.1",port:$port}}])
      | .routing.rules = (((.routing.rules // []) | map(select(.ruleTag != "qcascade"))) + [$rule])' "$orig" > "$new"
  else
    jq '.outbounds = ((.outbounds // []) | map(select(.tag != "qcascade")))
        | .routing.rules = ((.routing.rules // []) | map(select(.ruleTag != "qcascade")))' "$orig" > "$new"
  fi
  if cmp -s <(jq -S . "$orig") <(jq -S . "$new"); then rm -f "$orig" "$new"; ok "шаблон Xray уже в нужном состоянии"; return 0; fi

  # правило-«ловушка всего» выше нашего перехватит трафик раньше — предупредим
  if [ "$want" = on ]; then
    jq -r '.routing.rules[:-1][] | select((.ruleTag // "") != "qcascade")
           | select((keys - ["type","outboundTag","balancerTag","ruleTag","network"]) == [])
           | "  \(.outboundTag // .balancerTag)"' "$new" | grep -q . \
      && warn "в шаблоне Xray выше есть правило без условий — оно перехватит трафик раньше каскада"
  fi

  xb=$(xray_bin)
  if [ -n "$xb" ]; then
    out=$(XRAY_LOCATION_ASSET="$XUI_DIR/bin" "$xb" run -test -c "$new" 2>&1) \
      || { rm -f "$orig" "$new"; err "Xray не принял шаблон:"; printf '%s\n' "$out" | tail -5 >&2; return 1; }
  fi

  local t0; t0=$(date +%s)
  tpl_put "$db" "$new"
  systemctl restart x-ui
  if xray_check "$want" "$t0"; then
    ok "Xray: $( [ "$want" = on ] && echo "перехват включён ($QC_XRAY_MODE${QC_XRAY_LIST:+: $QC_XRAY_LIST})" || echo "перехват выключен" )"
    rm -f "$orig" "$new"; return 0
  fi
  err "Xray не поднялся с новым шаблоном — откатываю"
  if [ $rc = 3 ]; then sql "$db" "DELETE FROM settings WHERE key='xrayTemplateConfig';"; else tpl_put "$db" "$orig"; fi
  systemctl restart x-ui
  rm -f "$orig" "$new"; return 1
}
xray_check() { # ждём, что панель сгенерировала конфиг с/без нашего outbound и xray жив
  local want=$1 t0=$2 i f=$XUI_DIR/bin/config.json has
  for ((i=0; i<45; i++)); do
    sleep 1
    [ -f "$f" ] || continue
    [ "$(stat -c %Y "$f")" -ge "$t0" ] || continue
    xray_fresh "$t0" || continue
    has=$(jq -r 'any(.outbounds[]?; .tag=="qcascade")' "$f" 2>/dev/null || echo err)
    [ "$want" = on ] && [ "$has" = true ] && return 0
    [ "$want" = off ] && [ "$has" = false ] && return 0
  done
  return 1
}
xray_fresh() { # есть процесс xray, запущенный после t0 (не старый, переживший рестарт)
  local t0=$1 now p e
  now=$(date +%s)
  for p in $(pgrep -f "xray-linux-" 2>/dev/null); do
    e=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ') || continue
    [ -n "$e" ] && [ $((now - e)) -ge $((t0 - 1)) ] && return 0
  done
  return 1
}
xray_state() { # печатает режим из живого конфига
  local f=$XUI_DIR/bin/config.json
  [ -f "$f" ] || { echo "нет 3x-ui"; return; }
  jq -r '(.routing.rules // []) | map(select(.ruleTag=="qcascade")) | if length==0 then "off"
         else .[0] | if .user then "users: " + (.user|join(" ")) elif .inboundTag then "inbounds: " + (.inboundTag|join(" ")) else "all" end end' "$f" 2>/dev/null || echo "?"
}


cmd_xray() {
  need_root; load_env; defaults
  case ${1:-show} in
    on)   systemctl is-active -q "$SVC" && mh_healthy 5 || die "mihomo не работает — перехват не включаю (иначе клиенты останутся без сети)"
          xray_hook on ;;
    off)  xray_hook off ;;
    show) echo "перехват Xray: $(xray_state)"; echo "в env: QC_XRAY_MODE=$QC_XRAY_MODE${QC_XRAY_LIST:+ QC_XRAY_LIST=$QC_XRAY_LIST}" ;;
    list) detect_json | jq '{xui, inbounds, emails}' ;;
    *) die "qcascade xray on|off|show|list" ;;
  esac
}

# ───────────────────────────── визард ─────────────────────────────
wizard() {
  local a
  if [ "$(src_json | jq '.sources|length')" = 0 ] && [ -z "${QC_SUB_URL:-}" ]; then
    interactive || die "нужен источник нод: QC_SUB_URL=<ссылка Clash/Mihomo> qcascade install (или QTerm → Каскад)"
    say ""
    say "Ссылка Clash/Mihomo-подписки для этого каскада (лучше отдельный клиент со своим набором серверов;"
    say "QTerm → Каскад → Источники делает такого клиента сам). Шаблон имени нод в 3x-ui — {{INBOUND}}."
    ask QC_SUB_URL "Ссылка подписки"
    [ -n "$QC_SUB_URL" ] || die "без источника каскад не собрать"
  fi
  if interactive; then
    say ""
    say "Куда отправлять DIRECT из правил (ru-трафик и MATCH):"
    say "  DIRECT — напрямую с этого сервера;  MSK (или другая группа) — через неё"
    ask QC_DIRECT_TARGET "DIRECT →" "$QC_DIRECT_TARGET"

    if systemctl cat x-ui >/dev/null 2>&1; then
      say ""
      say "Клиенты 3x-ui (VLESS, Hysteria, встроенный AWG) через каскад:"
      say "  1) все  2) выбранные инбаунды  3) выбранные клиенты  4) никто"
      local def=1; case $QC_XRAY_MODE in inbounds) def=2 ;; users) def=3 ;; off) def=4 ;; esac
      ask a "Выбор" "$def"
      case $a in
        2) QC_XRAY_MODE=inbounds
           say "Инбаунды (tag | протокол | название):"; xray_inbounds | sed 's/^/  /'
           ask QC_XRAY_LIST "Теги через пробел" "$( [ "$def" = 2 ] && echo "$QC_XRAY_LIST")" ;;
        3) QC_XRAY_MODE=users
           say "Клиенты: $(xray_emails | tr '\n' ' ')"
           ask QC_XRAY_LIST "Имена через пробел" "$( [ "$def" = 3 ] && echo "$QC_XRAY_LIST")" ;;
        4) QC_XRAY_MODE=off; QC_XRAY_LIST="" ;;
        *) QC_XRAY_MODE=all; QC_XRAY_LIST="" ;;
      esac
    else
      QC_XRAY_MODE=off
    fi

    local ifs; ifs=$(awg_ifaces | cut -f1 | paste -sd' ' -)
    if [ -n "$ifs" ]; then
      say ""
      ask a "Клиенты AWG-панели ($ifs) тоже через каскад? (Y/n)" "$( [ "$QC_AWG_MODE" = off ] && echo n || echo y)"
      [[ "$a" =~ ^[YyДд] ]] && QC_AWG_MODE=all || QC_AWG_MODE=off
    fi
    local mt; mt=$(detect_json | jq -r '[.mtp.users[], .mtp.containers[].name] | join(" ")')
    if [ -n "$mt" ]; then
      say ""
      ask a "MTProto-прокси ($mt): трафик к Telegram — через каскад, группа TG? (Y/n)" "$( [ "$QC_MTP" = on ] && echo y || echo n)"
      [[ "$a" =~ ^[YyДд] ]] && QC_MTP=on || QC_MTP=off
    fi
  fi
  case $QC_XRAY_MODE in all|inbounds|users|off) ;; *) die "QC_XRAY_MODE: all|inbounds|users|off" ;; esac
  case $QC_AWG_MODE in all|list|off) ;; *) die "QC_AWG_MODE: all|list|off" ;; esac
  case $QC_MTP in on|off) ;; *) die "QC_MTP: on|off" ;; esac
  if [ "$QC_XRAY_MODE" = inbounds ] || [ "$QC_XRAY_MODE" = users ]; then
    [ -n "$QC_XRAY_LIST" ] || die "для режима $QC_XRAY_MODE нужен список (QC_XRAY_LIST)"
  fi
}

# ───────────────────────────── systemd ─────────────────────────────
write_units() {
  cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=qcascade — mihomo для каскада 3x-ui / AWG / MTProto
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=qcascade
Group=qcascade
Environment=SAFE_PATHS=$QC_ETC
ExecStart=$QC_BIN -d $QC_HOME -f $CFG
# сетевой перехват AWG / MTProto — после старта (ждёт tproxy-порт), снимается при остановке
ExecStartPost=+$QC_SELF nf up --wait
ExecStopPost=+$QC_SELF nf down
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$QC_HOME

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/$SVC-refresh.service <<EOF
[Unit]
Description=qcascade — обновить группы по источникам
After=network-online.target $SVC.service

[Service]
Type=oneshot
ExecStart=$QC_SELF refresh
EOF
  cat > /etc/systemd/system/$SVC-refresh.timer <<EOF
[Unit]
Description=qcascade — раз в час сверять источники

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

# ───────────────────────────── install ─────────────────────────────
cmd_install() {
  need_root
  command -v systemctl >/dev/null || die "нужен systemd"
  load_env; defaults
  local src; src=$(readlink -f "$0" 2>/dev/null || true)
  [ -f "$src" ] || die "запусти из файла: curl -fsSL <ссылка> -o qcascade.sh && bash qcascade.sh install"
  step "Зависимости"; deps; ok "curl jq sqlite3 nftables"

  step "Пользователь и каталоги"
  id qcascade >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$QC_HOME" --shell /usr/sbin/nologin qcascade
  install -d -m 755 "$QC_ETC" "$RSDIR" "$QC_LIB"
  install -d -m 750 -o qcascade -g qcascade "$QC_HOME" "$PROV_DIR"
  write_default_rules; write_default_groups; install_bundled_rulesets
  ok "$QC_ETC (источники: sources.json, правила: rules.yaml, группы: groups.conf, rule-sets/), данные: $QC_HOME"
  if [ -n "${QC_SOURCES_FILE:-}" ]; then   # источники от QTerm (до установки jq на сервере могло не быть)
    if [ -s "$QC_SOURCES_FILE" ]; then src_write < "$QC_SOURCES_FILE"; ok "источники из QTerm: $(src_json | jq '.sources|length')"; fi
    rm -f "$QC_SOURCES_FILE"
  fi

  step "Ядро mihomo"
  if [ -x "$QC_BIN" ] && [ "${QC_REINSTALL_CORE:-0}" != 1 ]; then ok "уже стоит: $(mh_ver)"
  else fetch_core "$QC_BIN"; ok "mihomo $(mh_ver)"; fi

  step "Настройка"
  if ! systemctl cat x-ui >/dev/null 2>&1 && [ "$QC_XRAY_MODE" != off ]; then
    warn "3x-ui не найден — перехват Xray выключен (включишь потом: qcascade xray on)"
    QC_XRAY_MODE=off
  fi
  wizard
  migrate_sources
  if ! systemctl is-active -q "$SVC"; then
    port_busy "$QC_PORT" && QC_PORT=$(pick_port "$QC_PORT")
    port_busy "$QC_TPROXY_PORT" && QC_TPROXY_PORT=$(pick_port "$QC_TPROXY_PORT")
    local ap=${QC_API##*:}; port_busy "$ap" && QC_API=127.0.0.1:$(pick_port "$ap")
  fi
  save_env; ok "настройки и секреты: $ENV_FILE (600)"

  step "Сервис"
  [ "$src" = "$QC_SELF" ] || install -D -m 755 "$src" "$QC_SELF"
  write_units
  systemctl enable -q "$SVC" "$SVC-refresh.timer"
  systemctl start "$SVC-refresh.timer"
  ok "$SVC.service + таймер обновления источников (1 ч)"

  step "Конфиг mihomo"
  cmd_apply || die "mihomo не запущен — перехват Xray не включаю"

  if [ "$QC_XRAY_MODE" != off ]; then
    step "Перехват трафика 3x-ui"
    xray_hook on || die "перехват не включён (mihomo работает, 3x-ui в прежнем состоянии)"
  elif [ "$(xray_state)" != off ] && [ "$(xray_state)" != "нет 3x-ui" ]; then
    xray_hook off || true
  fi

  step "Готово"
  cmd_status
  say ""
  say "Панель mihomo (zashboard) — через SSH-туннель:"
  say "  ssh -L ${QC_API##*:}:127.0.0.1:${QC_API##*:} root@<сервер>   →  http://127.0.0.1:${QC_API##*:}/ui"
  say "  адрес бэкенда 127.0.0.1:${QC_API##*:}, secret: grep QC_SECRET $ENV_FILE"
}

cmd_config() {
  need_root; load_env; defaults
  interactive || die "нужен терминал (или задай QC_* и запусти qcascade apply / qcascade xray on)"
  local old_mode=$QC_XRAY_MODE old_list=$QC_XRAY_LIST a
  ask a "Заменить подписку (источник SUB)? (y/N)" "n"
  if [[ "$a" =~ ^[YyДд] ]]; then ask QC_SUB_URL "Ссылка подписки"; migrate_sources; fi
  wizard; save_env
  cmd_apply || return 1
  if [ "$QC_XRAY_MODE" = off ]; then [ "$old_mode" = off ] || xray_hook off
  elif [ "$QC_XRAY_MODE" != "$old_mode" ] || [ "$QC_XRAY_LIST" != "$old_list" ] || [ "$(xray_state)" = off ]; then xray_hook on; fi
}

# ───────────────────────────── status ─────────────────────────────
# jq: по группе — нода, куда сейчас уходит трафик (сквозь вложенные группы; «~ИМЯ» — сырьё ноды из подписки)
JQ_GROUPS='
  def isgroup: (.type // "") | IN("Selector","Fallback","URLTest","LoadBalance","Relay");
  def walk($P; $g): reduce range(0;10) as $i ({cur:$g, grp:$g, done:false};
      if .done then . else ($P[.cur].now // null) as $n
        | if $n == null then .done = true
          elif $n == .cur then .grp = .cur | .done = true
          elif (.cur|startswith("~")) then .grp = .cur | .cur = $n | .done = true
          else .grp = .cur | .cur = $n end end);
  .P as $P | .R as $R
  | [ .G[] as $g | ($P[$g] // null) as $p
      | if $p == null then {name:$g, missing:true}
        else walk($P; $g) as $w
        | $w.cur as $leaf
        | (if ($P[$leaf] // null) != null and (($P[$leaf]|isgroup)|not) then $P[$leaf] else ($P[$w.grp] // {}) end) as $o
        | {name:$g, now:($p.now // null), node:$leaf, reserve:($R != "" and $leaf == $R),
           delay:( if ($leaf|IN("DIRECT","REJECT","REJECT-DROP")) then null
                   elif ($o.alive == false) then 0
                   elif (($o.history // [])|length) == 0 then -1
                   else (($o.history // [])|last|.delay // 0) end)}
        end ]'

groups_json() { # → JSON-массив состояния составных групп
  local gj px
  gj=$( [ -f "$GROUPS_F" ] && awk '!/^[ \t]*(#|$)/ && NF>=3 {print $1}' "$GROUPS_F" | jq -R . | jq -s . || echo '[]')
  px=$(api /proxies 10 2>/dev/null | jq '.proxies // {}' 2>/dev/null || echo '{}')
  jq -n --argjson P "$px" --argjson G "$gj" --arg R "$QC_RESERVE" '{P:$P, G:$G, R:$R}' | jq "$JQ_GROUPS"
}

cmd_status() {
  load_env; defaults
  [ "$(id -u)" = 0 ] && [ -n "${QC_SUB_URL:-}" ] && migrate_sources
  local json=0; [ "${1:-}" = --json ] && json=1
  local active=false ver="" xs gs='[]' nfa=false
  systemctl is-active -q "$SVC" 2>/dev/null && active=true
  if $active; then
    ver=$(api /version 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)
    gs=$(groups_json || echo '[]')
  fi
  xs=$(xray_state)
  nf_active && nfa=true
  local srcs='[]'
  [ "$(id -u)" = 0 ] && srcs=$(src_json | jq '[.sources[] | {name, type, enabled, prefix, meta: (.meta // {})}]')

  if [ $json = 1 ]; then
    local installed=false; [ -x "$QC_BIN" ] && installed=true
    local pend=false f   # источники/правила/группы правили после сборки конфига — ждут apply
    if [ -f "$CFG" ]; then for f in "$SOURCES" "$RULES" "$GROUPS_F"; do if [ "$f" -nt "$CFG" ]; then pend=true; fi; done; fi
    local subset=false; [ "$(printf '%s' "$srcs" | jq '[.[] | select(.enabled)] | length')" != 0 ] && subset=true
    jq -n --argjson active "$active" --arg ver "$ver" --arg xray "$xs" --argjson groups "$gs" \
          --slurpfile st <( [ -f "$STATE" ] && cat "$STATE" || echo '{}' ) --arg v "$VERSION" \
          --argjson installed "$installed" --arg dt "$QC_DIRECT_TARGET" --arg xm "$QC_XRAY_MODE" --arg xl "$QC_XRAY_LIST" \
          --arg mu "$QC_MIHOMO_URL" --arg api "$QC_API" --argjson port "${QC_PORT:-0}" --argjson sub "$subset" \
          --arg am "$QC_AWG_MODE" --arg ai "$QC_AWG_IFACES" --arg as "$QC_AWG_SRC" --arg mtp "$QC_MTP" \
          --arg res "$QC_RESERVE" --argjson nf "$nfa" --argjson srcs "$srcs" --arg mtpu "$QC_MTP_USERS" --argjson pend "$pend" \
      '{qcascade:$v, installed:$installed, mihomo:{active:$active, version:$ver}, xray:$xray, groups:$groups,
        state:($st[0] // {}), sources:$srcs, nf:$nf, pending:$pend,
        env:{directTarget:$dt, xrayMode:$xm, xrayList:$xl, mihomoUrl:$mu, api:$api, port:$port, subSet:$sub,
             awgMode:$am, awgIfaces:$ai, awgSrc:$as, mtp:$mtp, mtpUsers:$mtpu, reserve:$res}}'
    return 0
  fi
  printf '%sqcascade %s%s\n' "$C_B" "$VERSION" "$C_0"
  if $active; then printf '  mihomo    %sработает%s  %s  API %s\n' "$C_G" "$C_0" "${ver:-?}" "$QC_API"
  else printf '  mihomo    %sне работает%s  (journalctl -u %s)\n' "$C_R" "$C_0" "$SVC"; fi
  if [ -f "$STATE" ]; then
    printf '  источники %s\n' "$(jq -r '[.sources[]? | "\(.name)(\(.type)\(if .enabled then ": \(.nodes)" else ": выкл" end))"] | join(", ")' "$STATE")"
    printf '  ноды      %s  (сборка %s)\n' "$(jq '.nodes|length' "$STATE")" "$(jq -r '.built' "$STATE" | cut -c1-16 | tr T ' ')"
  fi
  [ -n "$QC_RESERVE" ] && printf '  резерв    %s\n' "$QC_RESERVE"
  printf '  xray      перехват: %s\n' "$xs"
  printf '  awg       %s\n' "$(case $QC_AWG_MODE in all) echo "все интерфейсы wg*/awg*";; list) echo "интерфейсы: $QC_AWG_IFACES";; *) echo "выключен";; esac)${QC_AWG_SRC:+ (только $QC_AWG_SRC)}"
  printf '  mtproto   %s\n' "$( [ "$QC_MTP" = on ] && echo "через каскад (Telegram → правила)" || echo "выключен")"
  if need_tproxy; then printf '  перехват  %s\n' "$($nfa && echo "правила nftables стоят" || echo "НЕ стоит — qcascade nf up / журнал сервиса")"; fi
  if $active && [ "$gs" != '[]' ]; then
    echo "  группы:"
    printf '%s' "$gs" | jq -r '.[] | if .missing then "    \(.name)\t—"
        else "    \(.name)\t→ \(.node)\t" + (if .delay == null then "напрямую"
             elif .delay > 0 then "\(.delay) мс" elif .delay < 0 then "ещё не проверялась" else "нет ответа" end) + (if .reserve then "  (резерв)" else "" end) end' | expand -t 12
  fi
  report_state
}

# ───────────────────────────── set / sources ─────────────────────────────
SET_KEYS="QC_SUB_URL QC_DIRECT_TARGET QC_XRAY_MODE QC_XRAY_LIST QC_AWG_MODE QC_AWG_IFACES QC_AWG_SRC QC_MTP QC_MTP_USERS QC_RESERVE QC_MIHOMO_URL QC_MIHOMO_REPO QC_PORT QC_API QC_TPROXY_PORT"
cmd_set() { # set K=V … | set - (K=V построчно из stdin — так секреты не светятся в ps)
  need_root; load_env; defaults
  local kv k v n=0 lines=()
  if [ "${1:-}" = - ] || [ $# -eq 0 ]; then
    while IFS= read -r kv || [ -n "$kv" ]; do kv=${kv%$'\r'}; [ -n "$kv" ] && lines+=("$kv"); done
  else lines=("$@"); fi
  for kv in "${lines[@]}"; do
    [[ "$kv" == *=* ]] || die "ожидается КЛЮЧ=значение: $kv"
    k=${kv%%=*}; v=${kv#*=}
    [[ " $SET_KEYS " == *" $k "* ]] || die "неизвестный ключ $k (можно: $SET_KEYS)"
    case $k in
      QC_XRAY_MODE) case $v in all|inbounds|users|off) ;; *) die "QC_XRAY_MODE: all|inbounds|users|off" ;; esac ;;
      QC_AWG_MODE) case $v in all|list|off) ;; *) die "QC_AWG_MODE: all|list|off" ;; esac ;;
      QC_MTP) case $v in on|off) ;; *) die "QC_MTP: on|off" ;; esac ;;
      QC_PORT|QC_TPROXY_PORT) [[ "$v" =~ ^[0-9]+$ ]] || die "$k — число" ;;
      QC_AWG_IFACES) [[ "$v" =~ ^[A-Za-z0-9._\ -]*$ ]] || die "QC_AWG_IFACES — имена интерфейсов через пробел" ;;
      QC_AWG_SRC) [[ "$v" =~ ^[0-9./\ ]*$ ]] || die "QC_AWG_SRC — IPv4-адреса/подсети через пробел" ;;
      QC_RESERVE) [[ "$v" != "~"* ]] || die "QC_RESERVE — имя ноды или WG-источника" ;;
    esac
    printf -v "$k" '%s' "$v"; n=$((n+1))
  done
  migrate_sources
  save_env
  ok "сохранено ключей: $n"
}

cmd_sources() {
  need_root; load_env; defaults
  migrate_sources
  case ${1:-get} in
    get) src_json ;;
    set) [ "${2:--}" = - ] || die "qcascade sources set - (JSON из stdin)"; src_write; ok "источников: $(src_json | jq '.sources|length')" ;;
    *) die "qcascade sources get | set -" ;;
  esac
}

# ───────────────────────────── прочее ─────────────────────────────
cmd_update_core() {
  need_root; load_env; defaults
  local tmp=$QC_LIB/mihomo.new old
  old=$(mh_ver); fetch_core "$tmp"
  SAFE_PATHS=$QC_ETC "$tmp" -t -d "$QC_HOME" -f "$CFG" >/dev/null 2>&1 || { rm -f "$tmp"; die "новое ядро не принимает текущий конфиг — оставляю $old"; }
  cp -f "$QC_BIN" "$QC_BIN.prev"; mv -f "$tmp" "$QC_BIN"
  systemctl restart "$SVC"
  if mh_healthy 90; then ok "ядро: $old → $(mh_ver)"
  else err "с новым ядром не поднялся — возвращаю $old"; mv -f "$QC_BIN.prev" "$QC_BIN"; systemctl restart "$SVC"; return 1; fi
}

cmd_uninstall() {
  need_root; load_env; defaults
  if systemctl cat x-ui >/dev/null 2>&1 && [ "$(xray_state)" != off ]; then xray_hook off || die "не снял перехват Xray — остановка mihomo оставила бы клиентов без сети"; fi
  systemctl disable --now "$SVC" "$SVC-refresh.timer" 2>/dev/null || true
  nf_down
  rm -f /etc/systemd/system/$SVC.service /etc/systemd/system/$SVC-refresh.service /etc/systemd/system/$SVC-refresh.timer
  systemctl daemon-reload
  rm -rf "$QC_LIB"; rm -f "$QC_SELF"
  if [ "${1:-}" = --purge ]; then
    rm -rf "$QC_ETC" "$QC_HOME"; userdel qcascade 2>/dev/null || true
    ok "удалено полностью"
  else
    ok "удалено; настройки, источники и правила оставлены в $QC_ETC (полностью: --purge)"
  fi
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

main() {
  local c=${1:-help}; shift || true
  case $c in
    install)            cmd_install "$@" ;;
    apply)              cmd_apply "$@" ;;
    refresh)            cmd_apply --if-changed --quiet ;;
    status)             cmd_status "$@" ;;
    sources)            cmd_sources "$@" ;;
    xray)               cmd_xray "$@" ;;
    detect)             need_root; load_env; defaults; detect_json ;;
    nf)                 cmd_nf "$@" ;;
    config)             cmd_config ;;
    update-core)        cmd_update_core ;;
    set)                cmd_set "$@" ;;
    logs)               journalctl -u "$SVC" -n "${1:-100}" --no-pager ;;
    uninstall)          cmd_uninstall "$@" ;;
    version|-v|--version) echo "qcascade $VERSION" ;;
    help|-h|--help|*)   usage ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
"""##
}
