#!/bin/sh
# Регрессия 2.0/2.1: проверки ndm «правило/цепочка уже есть» на Keenetic.
# Эмулятор iptables ведёт себя как прошивка: вывод цепочки с правилом NDM-match'а
# (ndmmark) обрывается на нём с rc=1, полный iptables-save обрывается в первой таблице.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi
ST="$WORK/state"; mkdir -p "$WORK/bin" "$ST"

cat > "$WORK/bin/iptables" <<'EOS'
#!/bin/sh
ST="$IPT_STATE"; t=filter; op=""; ch=""; num=""; rest=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w) ;;
        -t) t="$2"; shift ;;
        -S|-N|-F|-X|-A|-D|-C) op="$1"; ch="$2"; shift ;;
        -I) op=-I; ch="$2"; shift; case "${2:-}" in [0-9]*) num="$2"; shift ;; esac ;;
        *) rest="$rest${rest:+ }$1" ;;
    esac
    shift
done
d="$ST/$t"; mkdir -p "$d"; f="$d/$ch"
builtin() { case "$1" in PREROUTING|INPUT|FORWARD|OUTPUT|POSTROUTING) return 0 ;; esac; return 1; }
[ -f "$f" ] || builtin "$ch" && [ ! -f "$f" ] && : > "$f"
case "$op" in
    -S) [ -f "$f" ] || { echo "No chain/target/match by that name." >&2; exit 1; }
        if builtin "$ch"; then echo "-P $ch ACCEPT"; else echo "-N $ch"; fi
        while IFS= read -r r; do
            case "$r" in *ndmmark*) printf '%s' "-A $ch"; echo "Can't find library for match \`ndmmark'" >&2; exit 1 ;; esac
            echo "$r"
        done < "$f" ;;
    -N) [ -f "$f" ] && exit 1; : > "$f"; echo "$ch" >> "$d/.order" ;;
    -F) [ -f "$f" ] && : > "$f" ;;
    -X) rm -f "$f" ;;
    -A) echo "-A $ch $rest" >> "$f" ;;
    -I) awk -v n="${num:-1}" -v r="-A $ch $rest" 'NR == n { print r; done = 1 } { print } END { if (!done) print r }' "$f" > "$f.t" && mv "$f.t" "$f" ;;
    -D) grep -vxF -- "-A $ch $rest" "$f" > "$f.t" || true; mv "$f.t" "$f" ;;
    -C) grep -qxF -- "-A $ch $rest" "$f" ;;
esac
EOS
cat > "$WORK/bin/iptables-save" <<'EOS'
#!/bin/sh
ST="$IPT_STATE"
if [ "${1:-}" = "-t" ]; then tables="$2"; else tables="nat mangle filter"; fi
for t in $tables; do
    d="$ST/$t"; echo "*$t"
    for c in PREROUTING INPUT FORWARD OUTPUT POSTROUTING $(cat "$d/.order" 2>/dev/null); do
        [ -f "$d/$c" ] && echo ":$c - [0:0]"
    done
    for c in PREROUTING INPUT FORWARD OUTPUT POSTROUTING $(cat "$d/.order" 2>/dev/null); do
        [ -f "$d/$c" ] || continue
        while IFS= read -r r; do
            case "$r" in *ndmmark*) echo "Can't find library for match \`ndmmark'" >&2; exit 1 ;; esac
            echo "$r"
        done < "$d/$c"
    done
    echo COMMIT
done
EOS
chmod +x "$WORK/bin/iptables" "$WORK/bin/iptables-save"
export IPT_STATE="$ST"

# Состояние «как на роутере»: в nat PREROUTING правило прошивки с ndmmark —
# полный iptables-save обрывается в nat и до mangle не доходит.
mkdir -p "$ST/nat" "$ST/mangle"
printf '%s\n' '-A PREROUTING -j _NDM_DNAT' '-A PREROUTING -m ndmmark --mark 0x1 -j ACCEPT' > "$ST/nat/PREROUTING"
printf '%s\n' '-A INPUT -m connndmmark --mark 0x1 -j ACCEPT' > "$ST/mangle/INPUT"
: > "$ST/mangle/PREROUTING"

# библиотека: хелперы из libs/main + ndm, пути к iptables — на эмулятор
{
    echo "IPSET_TABLE_NAME=KVAS_LIST"
    sed -n '/^ipt_chain_rules() {/,/^}/p; /^ipt_chain_exists() {/,/^}/p; /^save_iptables() {/,/^}/p' "$ROOT/opt/bin/libs/main"
    sed '/^\. \/opt\/apps\/kvas\/bin\/libs\/main/d' "$ROOT/opt/etc/ndm/ndm"
    # заглушки окружения роутера (после ndm — переопределяют)
    cat <<'EOS'
log_warning() { :; }; error() { echo "ERR $*" >&2; }; get_local_inface() { echo br0; }
ip4__chain__exclude_source_by_config() { :; }; ip4__ipset__fill_destination_excluded() { :; }
ip4__route__add_table() { :; }; ip4__rule__add_mark_to_table() { :; }; ip4__ipset__create() { :; }
EOS
} | sed "s|/opt/sbin/iptables-save|$WORK/bin/iptables-save|g; s|/opt/sbin/iptables|$WORK/bin/iptables|g" > "$WORK/lib.sh"

run() { $RUN -c ". '$WORK/lib.sh'; $1"; }
count() { grep -cF -- "$2" "$ST/$1" 2>/dev/null || true; }

# 1) повторные прогоны хука не дублируют прыжки
for _ in 1 2 3; do
    run 'ip4__mark__create_chain; ip4__add_routing_for_home mangle KVAS_MARK; ip4__dns__add_routing " -i br0"'
done
[ "$(count mangle/PREROUTING '-j KVAS_MARK')" -eq 1 ] || { echo "FAIL: дубли прыжка в KVAS_MARK"; cat "$ST/mangle/PREROUTING"; exit 1; }
[ "$(count nat/PREROUTING '-j KVAS_DNS')" -eq 1 ]     || { echo "FAIL: дубли прыжка в KVAS_DNS"; cat "$ST/nat/PREROUTING"; exit 1; }
# DNS-прыжок встал сразу после _NDM_DNAT (позиция по ipt_chain_rules, а не по обрывку дампа)
sed -n 2p "$ST/nat/PREROUTING" | grep -qF -- '-j KVAS_DNS' || { echo "FAIL: позиция KVAS_DNS"; cat "$ST/nat/PREROUTING"; exit 1; }
[ "$(count nat/KVAS_DNS '127.0.0.1:9753')" -eq 2 ]    || { echo "FAIL: KVAS_DNS неполна"; exit 1; }
grep -q -- '--save-mark' "$ST/mangle/KVAS_MARK"         || { echo "FAIL: KVAS_MARK неполна"; exit 1; }
n_mark=$(grep -c . "$ST/mangle/KVAS_MARK")

# 2) NDM сделал -F: пустые цепочки пересобираются, прыжки не дублируются
: > "$ST/mangle/KVAS_MARK"; : > "$ST/nat/KVAS_DNS"
run 'ip4__mark__create_chain; ip4__add_routing_for_home mangle KVAS_MARK; ip4__dns__add_routing " -i br0"'
[ "$(grep -c . "$ST/mangle/KVAS_MARK")" -eq "$n_mark" ] || { echo "FAIL: KVAS_MARK не пересобрана"; cat "$ST/mangle/KVAS_MARK"; exit 1; }
[ "$(count nat/KVAS_DNS '127.0.0.1:9753')" -eq 2 ]      || { echo "FAIL: KVAS_DNS не пересобрана"; exit 1; }
[ "$(count mangle/PREROUTING '-j KVAS_MARK')" -eq 1 ]   || { echo "FAIL: дубль после пересборки"; exit 1; }

# 3) эмуляция save_iptables видит все таблицы, несмотря на обрывы
out=$(run 'save_iptables')
for t in nat mangle filter; do printf '%s\n' "$out" | grep -qx "\*$t" || { echo "FAIL: save_iptables без $t"; exit 1; }; done
printf '%s\n' "$out" | grep -qF -- '-A PREROUTING -i br0 -m set --match-set KVAS_LIST dst -j KVAS_MARK' || { echo 'FAIL: save_iptables без mangle-правил'; exit 1; }
