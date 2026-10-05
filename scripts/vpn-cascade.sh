#!/usr/bin/env bash
# qcascade — каскад на VPS с 3x-ui: трафик клиентов (VLESS / Hysteria / AWG) → mihomo
# с правилами как на Кинетиках → ноды из единой подписки.
#
#   qcascade install            установка (визард; без tty — из переменных QC_*)
#   qcascade apply              пересобрать конфиг mihomo, проверить, применить (откат при сбое)
#   qcascade refresh            то же, только если изменилась подписка/правила (таймер раз в час)
#   qcascade status [--json]    состояние: mihomo, группы, перехват xray, пропущенные rule-sets
#   qcascade xray on|off|show   перехват трафика клиентов 3x-ui в mihomo (list --json — инбаунды и клиенты)
#   qcascade config             поменять подписку / DIRECT / кого каскадить (визард)
#   qcascade update-core        обновить ядро mihomo (с проверкой и откатом)
#   qcascade set K=V… | set -   поменять настройки (QC_SUB_URL, QC_DIRECT_TARGET, QC_XRAY_MODE…); «-» — строки K=V из stdin
#   qcascade logs               журнал mihomo
#   qcascade uninstall [--purge]
#
# Секреты (ссылка подписки, secret API) — только в /etc/qcascade/env (600) или в переменных
# окружения при запуске: QC_SUB_URL=... qcascade install. В скрипт ничего не вшивать.
#
# Неинтерактивно (для QTerm): QC_SUB_URL, QC_DIRECT_TARGET, QC_XRAY_MODE=all|inbounds|users|off,
# QC_XRAY_LIST="tag1 tag2" / "PC S26", QC_MIHOMO_URL (свой бинарь .gz или голый),
# QC_MIHOMO_REPO=owner/repo + QC_GH_TOKEN (релиз из приватного репо, напр. сборка ff148).

set -Eeuo pipefail
VERSION="1.2.0"

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
RSDIR=$QC_ETC/rule-sets
STATE=$QC_HOME/state.json
SUB_CACHE=$QC_HOME/providers/sub.yaml
BK=$QC_ETC/backup
SVC=qcascade
XUI_DIR=${XUI_DIR:-/usr/local/x-ui}
ENV_KEYS="QC_SUB_URL QC_SECRET QC_PORT QC_API QC_DIRECT_TARGET QC_XRAY_MODE QC_XRAY_LIST QC_MIHOMO_URL QC_MIHOMO_REPO"

# ───────────────────────────── вывод ─────────────────────────────
if [ -t 1 ]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else C_G=; C_Y=; C_R=; C_B=; C_D=; C_0=; fi
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
  : "${QC_PORT:=7893}" "${QC_API:=127.0.0.1:9090}" "${QC_DIRECT_TARGET:=DIRECT}" \
    "${QC_XRAY_MODE:=all}" "${QC_XRAY_LIST:=}" "${QC_MIHOMO_URL:=}" "${QC_MIHOMO_REPO:=}" "${QC_SUB_URL:=}"
  [ -n "${QC_SECRET:-}" ] || QC_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
}

# ───────────────────────────── зависимости ─────────────────────────────
deps() {
  local miss=() b
  for b in curl jq sqlite3 gzip ss; do command -v "$b" >/dev/null || miss+=("$b"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  command -v apt-get >/dev/null || die "нет: ${miss[*]} (и нет apt-get)"
  say "ставлю: ${miss[*]}"
  local pk=() m
  for m in "${miss[@]}"; do case $m in ss) pk+=(iproute2) ;; *) pk+=("$m") ;; esac; done
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

# ───────────────────────────── подписка ─────────────────────────────
fetch_sub() { # fetch_sub <куда>
  local out=$1
  [ -n "$QC_SUB_URL" ] || { err "не задана ссылка подписки (QC_SUB_URL)"; return 1; }
  curl -fsSL --max-time 40 -A "clash.meta/mihomo" -o "$out" "$QC_SUB_URL" \
    || { err "подписка не скачалась (проверь ссылку и доступ к панели)"; return 1; }
  if ! grep -qE '^proxies:' "$out"; then
    err "это не Clash/Mihomo-подписка (нет секции proxies:). Нужна ссылка Clash/Mihomo из настроек подписки 3x-ui"
    return 1
  fi
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

# ───────────────────────────── сборка конфига ─────────────────────────────
yq1() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }   # YAML single-quoted
rx_esc() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/]/\\&/g'; }

# build_config <sub.yaml> <out.yaml> <state.json>
build_config() {
  local sub=$1 out=$2 st=$3 tmpd
  tmpd=$(mktemp -d)
  # имена нод (только «нормальные» — инфо-ноды с эмодзи/пробелами пропускаем)
  sub_names "$sub" | awk 'NF' | awk '!seen[$0]++' > "$tmpd/all"
  grep -E '^[A-Za-z0-9._-]+$' "$tmpd/all" > "$tmpd/names" || true
  [ -s "$tmpd/names" ] || { rm -rf "$tmpd"; err "в подписке нет нод (или имена не в формате {{INBOUND}})"; return 1; }

  # составные группы
  awk '!/^[ \t]*(#|$)/ && NF>=3' "$GROUPS_F" > "$tmpd/groups" || true
  awk '{print $1}' "$tmpd/groups" > "$tmpd/gnames"

  # rule-providers: перепись путей, пропуск file-провайдеров без файла
  awk -v rsdir="$RSDIR" -v miss="$tmpd/missing" '
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
    END { if (sec) flush() }' "$RULES" > "$tmpd/providers"
  touch "$tmpd/missing"

  # rules: пропуск правил с отсутствующими rule-set, замена DIRECT, сбор целей
  awk -v miss="$tmpd/missing" -v dt="$QC_DIRECT_TARGET" -v tg="$tmpd/targets" '
    BEGIN { while ((getline l < miss) > 0) m[l]=1 }
    /^[^ \t#]/ { sec = ($0 ~ /^rules:[ \t]*$/); if (sec) print "rules:"; next }
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
    { print }' "$RULES" > "$tmpd/rules"
  touch "$tmpd/targets"

  # ── proxy-groups ──
  {
    echo "proxy-groups:"
    # одноимённые группы на каждую ноду (кроме совпадающих с именем составной группы)
    while IFS= read -r n; do
      grep -qxF -- "$n" "$tmpd/gnames" && continue
      printf '  - { name: %s, type: select, use: [SUB], filter: %s }\n' "$(yq1 "$n")" "$(yq1 "^$(rx_esc "$n")\$")"
    done < "$tmpd/names"
    # составные
    local gname gtype gint members m res rx
    while read -r gname gtype gint members; do
      res=()
      for m in $members; do
        [ "$m" = "$gname" ] && continue
        if grep -qxF -- "$m" "$tmpd/names" || grep -qxF -- "$m" "$tmpd/gnames"; then res+=("$m"); else echo "$gname: $m" >> "$tmpd/skipped"; fi
      done
      echo "  - name: $(yq1 "$gname")"
      echo "    type: $gtype"
      if grep -qxF -- "$gname" "$tmpd/names"; then
        # имя группы совпадает с нодой (MSK): берём участников прямо из подписки фильтром
        rx=""; for m in $members; do grep -qxF -- "$m" "$tmpd/names" && rx="$rx|$(rx_esc "$m")"; done
        echo "    use: [SUB]"
        echo "    filter: $(yq1 "^(${rx#|})\$")"
      elif [ ${#res[@]} -gt 0 ]; then
        printf '    proxies: ['; local first=1
        for m in "${res[@]}"; do [ $first = 1 ] || printf ', '; printf '%s' "$(yq1 "$m")"; first=0; done
        printf ']\n'
      else
        echo "    proxies: [DIRECT]"
        echo "$gname" >> "$tmpd/empty"
      fi
      if [ "$gtype" != select ]; then
        echo "    url: https://www.gstatic.com/generate_204"
        echo "    interval: ${gint:-60}"
        echo "    timeout: 3000"
        echo "    lazy: false"
      fi
    done < "$tmpd/groups"
    # заглушки для целей правил, которых нет нигде
    sort -u "$tmpd/targets" | while IFS= read -r t; do
      case "$t" in DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE|GLOBAL|"") continue ;; esac
      grep -qxF -- "$t" "$tmpd/gnames" && continue
      grep -qxF -- "$t" "$tmpd/names" && continue
      echo "  - { name: $(yq1 "$t"), type: select, proxies: [DIRECT] }"
      echo "$t" >> "$tmpd/placeholders"
    done
  } > "$tmpd/pg"
  touch "$tmpd/empty" "$tmpd/placeholders" "$tmpd/skipped"

  # ── итоговый конфиг ──
  {
    cat <<EOF
# Сгенерировано qcascade $VERSION — не править руками.
# Правила: $RULES   Группы: $GROUPS_F   Применить: qcascade apply
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

proxy-providers:
  SUB:
    type: http
    url: $(yq1 "$QC_SUB_URL")
    path: ./providers/sub.yaml
    interval: 3600
    proxy: DIRECT
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      timeout: 3000
      lazy: true

EOF
    cat "$tmpd/pg"; echo
    cat "$tmpd/providers"; echo
    cat "$tmpd/rules"
  } > "$out"

  jq -n --rawfile names "$tmpd/names" --rawfile missing "$tmpd/missing" --rawfile ph "$tmpd/placeholders" \
        --rawfile empty "$tmpd/empty" --rawfile skipped "$tmpd/skipped" --arg ts "$(date -Is)" '
    def lines: split("\n")|map(select(length>0));
    {built:$ts, nodes:($names|lines), missingRulesets:($missing|lines),
     placeholders:($ph|lines), emptyGroups:($empty|lines), skippedMembers:($skipped|lines)}' > "$st"
  rm -rf "$tmpd"
}

mh_test() { # mh_test <config>
  SAFE_PATHS=$QC_ETC "$QC_BIN" -t -d "$QC_HOME" -f "$1" 2>&1 | grep -vE 'level=info' | tail -5
  SAFE_PATHS=$QC_ETC "$QC_BIN" -t -d "$QC_HOME" -f "$1" >/dev/null 2>&1
}
api() { curl -fsS --max-time "${2:-5}" -H "Authorization: Bearer $QC_SECRET" "http://$QC_API$1"; }
mh_healthy() { # ждём API до N сек
  local n=${1:-60} i
  for ((i=0; i<n; i++)); do
    systemctl is-active -q "$SVC" || { sleep 1; continue; }
    api /version >/dev/null 2>&1 && return 0
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
  install -d -m 755 "$QC_ETC" "$RSDIR"; install -d -m 750 -o qcascade -g qcascade "$QC_HOME" "$QC_HOME/providers"
  write_default_rules; write_default_groups; install_bundled_rulesets

  local sub_new new st_new
  sub_new=$(mktemp "$QC_HOME/.sub.XXXX"); new=$(mktemp "$QC_ETC/.config.XXXX"); st_new=$(mktemp "$QC_HOME/.state.XXXX")
  CLEAN+=("$sub_new" "$new" "$st_new")
  if ! fetch_sub "$sub_new"; then
    [ "$if_changed" = 1 ] && { warn "подписка недоступна — оставляю текущий конфиг"; return 0; }
    return 1
  fi
  build_config "$sub_new" "$new" "$st_new" || return 1

  if [ "$if_changed" = 1 ] && [ -f "$CFG" ] && cmp -s "$new" "$CFG" && systemctl is-active -q "$SVC"; then
    install -m 640 -o qcascade -g qcascade "$sub_new" "$SUB_CACHE"
    say "без изменений"; return 0
  fi

  # провайдер стартует с кэша — кладём свежую подписку заранее
  install -m 640 -o qcascade -g qcascade "$sub_new" "$SUB_CACHE"
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
    ok "mihomo применил конфиг ($(jq '.nodes|length' "$STATE") нод в подписке)"
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
  x=$(jq -r '.missingRulesets|join(", ")' "$STATE"); [ -n "$x" ] && warn "нет файлов rule-set: $x — их правила пропущены (положи .mrs в $RSDIR и qcascade apply)"
  x=$(jq -r '.placeholders|join(", ")' "$STATE");    [ -n "$x" ] && warn "правила ссылаются на то, чего нет в подписке: $x → временно DIRECT"
  x=$(jq -r '.emptyGroups|join(", ")' "$STATE");     [ -n "$x" ] && warn "группы без единой ноды из подписки: $x → временно DIRECT"
  return 0
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
    list) # инбаунды и клиенты 3x-ui этого сервера — для выбора «кого каскадить»
      if ! systemctl cat x-ui >/dev/null 2>&1; then echo '{"xui":false,"inbounds":[],"emails":[]}'; return 0; fi
      local ib em
      ib=$(xray_inbounds | jq -R 'split("|") | {tag:.[0], protocol:.[1], remark:(.[2] // "")}' | jq -s .)
      em=$(xray_emails | jq -R . | jq -s .)
      jq -n --argjson ib "$ib" --argjson em "$em" '{xui:true, inbounds:$ib, emails:$em}' ;;
    *) die "qcascade xray on|off|show|list" ;;
  esac
}

# ───────────────────────────── визард ─────────────────────────────
wizard() {
  local a
  if [ -z "$QC_SUB_URL" ]; then
    interactive || die "нужна ссылка подписки: QC_SUB_URL=... qcascade install"
    say ""
    say "Ссылка Clash/Mihomo-подписки с главной MSK для отдельного клиента этого сервера"
    say "(3x-ui → Настройки подписки → Clash/Mihomo; шаблон имени {{INBOUND}})."
    ask QC_SUB_URL "Ссылка подписки"
    [ -n "$QC_SUB_URL" ] || die "без подписки каскад не собрать"
  fi
  if interactive; then
    say ""
    say "Куда отправлять DIRECT из правил (ru-трафик и MATCH):"
    say "  DIRECT — напрямую с этого сервера;  MSK (или другая группа) — через неё"
    ask QC_DIRECT_TARGET "DIRECT →" "$QC_DIRECT_TARGET"

    if systemctl cat x-ui >/dev/null 2>&1; then
      say ""
      say "Кого пускать через каскад:"
      say "  1) всех клиентов всех инбаундов (VLESS, Hysteria, AWG)"
      say "  2) выбранные инбаунды"
      say "  3) выбранных клиентов (по имени)"
      say "  4) никого (только поставить mihomo)"
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
  fi
  case $QC_XRAY_MODE in all|inbounds|users|off) ;; *) die "QC_XRAY_MODE: all|inbounds|users|off" ;; esac
  if [ "$QC_XRAY_MODE" = inbounds ] || [ "$QC_XRAY_MODE" = users ]; then
    [ -n "$QC_XRAY_LIST" ] || die "для режима $QC_XRAY_MODE нужен список (QC_XRAY_LIST)"
  fi
}

# ───────────────────────────── systemd ─────────────────────────────
write_units() {
  cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=qcascade — mihomo для каскада 3x-ui
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=qcascade
Group=qcascade
Environment=SAFE_PATHS=$QC_ETC
ExecStart=$QC_BIN -d $QC_HOME -f $CFG
Restart=always
RestartSec=3
LimitNOFILE=1048576
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
Description=qcascade — обновить группы по подписке
After=network-online.target $SVC.service

[Service]
Type=oneshot
ExecStart=$QC_SELF refresh
EOF
  cat > /etc/systemd/system/$SVC-refresh.timer <<EOF
[Unit]
Description=qcascade — раз в час сверять подписку

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
  step "Зависимости"; deps; ok "curl jq sqlite3"

  step "Пользователь и каталоги"
  id qcascade >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$QC_HOME" --shell /usr/sbin/nologin qcascade
  install -d -m 755 "$QC_ETC" "$RSDIR" "$QC_LIB"
  install -d -m 750 -o qcascade -g qcascade "$QC_HOME" "$QC_HOME/providers"
  write_default_rules; write_default_groups; install_bundled_rulesets
  ok "$QC_ETC (правила: rules.yaml, группы: groups.conf, rule-sets/), данные: $QC_HOME"

  step "Ядро mihomo"
  if [ -x "$QC_BIN" ] && [ "${QC_REINSTALL_CORE:-0}" != 1 ]; then ok "уже стоит: $(mh_ver)"
  else fetch_core "$QC_BIN"; ok "mihomo $(mh_ver)"; fi

  step "Настройка"
  if ! systemctl cat x-ui >/dev/null 2>&1 && [ "$QC_XRAY_MODE" != off ]; then
    warn "3x-ui не найден — ставлю только mihomo, перехват включишь потом: qcascade xray on"
    QC_XRAY_MODE=off
  fi
  wizard
  # порты: свободные, если не заданы явно и заняты чужими
  if ! systemctl is-active -q "$SVC"; then
    port_busy "$QC_PORT" && QC_PORT=$(pick_port "$QC_PORT")
    local ap=${QC_API##*:}; port_busy "$ap" && QC_API=127.0.0.1:$(pick_port "$ap")
  fi
  save_env; ok "настройки и секреты: $ENV_FILE (600)"

  step "Сервис"
  [ "$src" = "$QC_SELF" ] || install -D -m 755 "$src" "$QC_SELF"
  write_units
  systemctl enable -q "$SVC" "$SVC-refresh.timer"
  systemctl start "$SVC-refresh.timer"
  ok "$SVC.service + таймер обновления подписки (1 ч)"

  step "Конфиг mihomo"
  cmd_apply || die "mihomo не запущен — перехват Xray не включаю"

  if [ "$QC_XRAY_MODE" != off ]; then
    step "Перехват трафика 3x-ui"
    xray_hook on || die "перехват не включён (mihomo работает, 3x-ui в прежнем состоянии)"
  fi

  step "Готово"
  cmd_status
  say ""
  say "Панель mihomo (zashboard) — через SSH-туннель:"
  say "  ssh -L ${QC_API##*:}:127.0.0.1:${QC_API##*:} root@<сервер>   →  http://127.0.0.1:${QC_API##*:}/ui"
  say "  адрес бэкенда 127.0.0.1:${QC_API##*:}, secret: grep QC_SECRET $ENV_FILE"
  if [ -n "$(jq -r '.missingRulesets|join(" ")' "$STATE" 2>/dev/null)" ]; then
    say ""
    say "Локальные .mrs с Кинетика (на роутере):"
    say "  scp /opt/etc/mihomo/rule-sets/*.mrs root@<сервер>:$RSDIR/   затем здесь: qcascade apply"
  fi
}

cmd_config() {
  need_root; load_env; defaults
  interactive || die "нужен терминал (или задай QC_* и запусти qcascade apply / qcascade xray on)"
  local old_mode=$QC_XRAY_MODE old_list=$QC_XRAY_LIST a
  ask a "Сменить ссылку подписки? (y/N)" "n"; [[ "$a" =~ ^[YyДд] ]] && QC_SUB_URL=""
  wizard; save_env
  cmd_apply || return 1
  if [ "$QC_XRAY_MODE" = off ]; then [ "$old_mode" = off ] || xray_hook off
  elif [ "$QC_XRAY_MODE" != "$old_mode" ] || [ "$QC_XRAY_LIST" != "$old_list" ] || [ "$(xray_state)" = off ]; then xray_hook on; fi
}

# ───────────────────────────── status ─────────────────────────────
# jq: по группе — выбранная нода (идём по цепочке групп до ноды подписки) и её последняя задержка
JQ_GROUPS='
  def leaf($P; $g): reduce range(0;8) as $i ({cur:$g, done:false};
      if .done then . else ($P[.cur].now // null) as $n
        | if $n == null or $n == .cur then .done = true else .cur = $n end end) | .cur;
  .P as $P | .L as $L
  | [ .G[] as $g | ($P[$g] // null) as $p
      | if $p == null then {name:$g, missing:true}
        else leaf($P; $g) as $leaf
        | {name:$g, now:($p.now // null), node:$leaf,
           delay:( if ($leaf|IN("DIRECT","REJECT","REJECT-DROP")) then null
                   else (($L[$leaf].history // [])|last|.delay // 0) end)}
        end ]'

groups_json() { # → JSON-массив состояния групп из groups.conf
  local gj px lp
  gj=$( [ -f "$GROUPS_F" ] && awk '!/^[ \t]*(#|$)/ && NF>=3 {print $1}' "$GROUPS_F" | jq -R . | jq -s . || echo '[]')
  px=$(api /proxies 10 2>/dev/null | jq '.proxies // {}' 2>/dev/null || echo '{}')
  lp=$(api /providers/proxies/SUB 10 2>/dev/null | jq '[.proxies[]? | {key:.name, value:.}] | from_entries' 2>/dev/null || echo '{}')
  jq -n --argjson P "$px" --argjson L "$lp" --argjson G "$gj" '{P:$P, L:$L, G:$G}' | jq "$JQ_GROUPS"
}

cmd_status() {
  load_env; defaults
  local json=0; [ "${1:-}" = --json ] && json=1
  local active=false ver="" xs gs='[]'
  systemctl is-active -q "$SVC" 2>/dev/null && active=true
  if $active; then
    ver=$(api /version 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)
    gs=$(groups_json || echo '[]')
  fi
  xs=$(xray_state)

  if [ $json = 1 ]; then
    local installed=false; [ -x "$QC_BIN" ] && installed=true
    jq -n --argjson active "$active" --arg ver "$ver" --arg xray "$xs" --argjson groups "$gs" \
          --slurpfile st <( [ -f "$STATE" ] && cat "$STATE" || echo '{}' ) --arg v "$VERSION" \
          --argjson installed "$installed" --arg dt "$QC_DIRECT_TARGET" --arg xm "$QC_XRAY_MODE" --arg xl "$QC_XRAY_LIST" \
          --arg mu "$QC_MIHOMO_URL" --arg api "$QC_API" --argjson port "${QC_PORT:-0}" --argjson sub "$( [ -n "$QC_SUB_URL" ] && echo true || echo false )" \
      '{qcascade:$v, installed:$installed, mihomo:{active:$active, version:$ver}, xray:$xray, groups:$groups, state:($st[0] // {}),
        env:{directTarget:$dt, xrayMode:$xm, xrayList:$xl, mihomoUrl:$mu, api:$api, port:$port, subSet:$sub}}'
    return 0
  fi
  printf '%sqcascade %s%s\n' "$C_B" "$VERSION" "$C_0"
  if $active; then printf '  mihomo    %sработает%s  %s  API %s\n' "$C_G" "$C_0" "${ver:-?}" "$QC_API"
  else printf '  mihomo    %sне работает%s  (journalctl -u %s)\n' "$C_R" "$C_0" "$SVC"; fi
  [ -f "$STATE" ] && printf '  подписка  %s нод  (сборка %s)\n' "$(jq '.nodes|length' "$STATE")" "$(jq -r '.built' "$STATE" | cut -c1-16 | tr T ' ')"
  printf '  xray      перехват: %s\n' "$xs"
  if $active && [ "$gs" != '[]' ]; then
    echo "  группы:"
    printf '%s' "$gs" | jq -r '.[] | if .missing then "    \(.name)\t—"
        else "    \(.name)\t→ \(.node)\t" + (if .delay == null then "напрямую"
             elif .delay > 0 then "\(.delay) мс" else "нет ответа" end) end' | expand -t 12
  fi
  report_state
}

# ───────────────────────────── set ─────────────────────────────
SET_KEYS="QC_SUB_URL QC_DIRECT_TARGET QC_XRAY_MODE QC_XRAY_LIST QC_MIHOMO_URL QC_MIHOMO_REPO QC_PORT QC_API"
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
      QC_PORT) [[ "$v" =~ ^[0-9]+$ ]] || die "QC_PORT — число" ;;
    esac
    printf -v "$k" '%s' "$v"; n=$((n+1))
  done
  save_env
  ok "сохранено ключей: $n"
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
  rm -f /etc/systemd/system/$SVC.service /etc/systemd/system/$SVC-refresh.service /etc/systemd/system/$SVC-refresh.timer
  systemctl daemon-reload
  rm -rf "$QC_LIB"; rm -f "$QC_SELF"
  if [ "${1:-}" = --purge ]; then
    rm -rf "$QC_ETC" "$QC_HOME"; userdel qcascade 2>/dev/null || true
    ok "удалено полностью"
  else
    ok "удалено; настройки и правила оставлены в $QC_ETC (полностью: --purge)"
  fi
}

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local c=${1:-help}; shift || true
  case $c in
    install)            cmd_install "$@" ;;
    apply)              cmd_apply "$@" ;;
    refresh)            cmd_apply --if-changed --quiet ;;
    status)             cmd_status "$@" ;;
    xray)               cmd_xray "$@" ;;
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
