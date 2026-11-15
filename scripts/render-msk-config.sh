#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TEMPLATE="$ROOT_DIR/configs/msk-config.template.json"
if [[ "$#" -ge 1 ]]; then SECRETS="$1"; else SECRETS="$ROOT_DIR/configs/msk-secrets"; fi
if [[ "$#" -ge 2 ]]; then OUTPUT="$2"; else OUTPUT="$ROOT_DIR/configs/msk-config.rendered.json"; fi

[[ -f "$TEMPLATE" ]] || { echo "Не найден шаблон: $TEMPLATE" >&2; exit 1; }
[[ -f "$SECRETS" ]] || { echo "Не найден файл секретов: $SECRETS" >&2; echo "Скопируйте configs/msk-secrets.example в configs/msk-secrets." >&2; exit 1; }

for cmd in envsubst jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Не найдена команда '$cmd'. Установите gettext-base и jq." >&2; exit 1; }
done

# Файл секретов является shell-файлом и выполняется через source.
# Используйте только собственный файл, который вы создали и проверили.
set -a
# shellcheck disable=SC1090
source "$SECRETS"
set +a

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if [[ -z "$(printenv "$name" || true)" ]]; then
    echo "Не заполнена обязательная переменная: $name" >&2
    exit 1
  fi
done <<'VARS'
RU_CLIENT_01
RU_CLIENT_02
RU_CLIENT_03
RU_CLIENT_04
RU_CLIENT_05
RU_CLIENT_06
RU_CLIENT_07
RU_CLIENT_08
RU_CLIENT_09
RU_CLIENT_10
RU_CLIENT_11
RU_CLIENT_TEST
RU_REALITY_PRIVATE_KEY
RU_REALITY_DEST
RU_REALITY_SHORT_ID
RIGA_IP
RIGA_UUID
RIGA_PUBLIC_KEY
RIGA_SHORT_ID
RIGA_NEW_IP
RIGA_NEW_UUID
RIGA_NEW_PUBLIC_KEY
RIGA_NEW_SHORT_ID
RIGA5_IP
RIGA5_UUID
RIGA5_PUBLIC_KEY
RIGA5_SHORT_ID
KZ_IP
KZ_UUID
KZ_PUBLIC_KEY
KZ_SHORT_ID
VARS

mkdir -p "$(dirname -- "$OUTPUT")"
tmp="$(mktemp "$(dirname -- "$OUTPUT")/.msk-config.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
envsubst < "$TEMPLATE" > "$tmp"

if grep -Eq '\$[{][A-Za-z_][A-Za-z0-9_]*[}]' "$tmp"; then
  echo "В конфиге остались незаполненные переменные." >&2
  exit 1
fi
jq empty "$tmp" || { echo "Некорректный JSON. Итоговый файл не сохранен." >&2; exit 1; }

chmod 600 "$tmp"
mv -f "$tmp" "$OUTPUT"
trap - EXIT
echo "Конфигурация собрана: $OUTPUT"
echo "Права доступа: 600"
echo "Xray не перезапускался. Для проверки выполните:"
echo "xray run -test -config \"$OUTPUT\""
