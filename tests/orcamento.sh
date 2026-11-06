#!/usr/bin/env bash
# Orçamento A-01: atrasos reais; medição externa ao relógio da implementação.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${1:-$root/verifica-reinicio.sh}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
checks=0 failures=0
check() {
    checks=$((checks + 1))
    if ! "$@"; then
        failures=$((failures + 1))
        printf 'FALHOU orcamento: %s: %s\n' "$name" "$*" >&2
    fi
}
run() {
    local name="$1" budget="$2" data_delay="$3" meta_delay="$4" post_delay="$5"
    local expected="$6" meta_exit="$7" ignore_term="$8" start end elapsed status=0 grant gap
    local folder="$work/$name"
    mkdir "$folder"
    # date mede independentemente de /proc/uptime e da variavel SECONDS.
    start="$(date +%s%N)"
    A01_BUDGET="$budget" A01_DATA_DELAY="$data_delay" A01_META_DELAY="$meta_delay" \
        A01_POST_DATA_DELAY="$post_delay" A01_META_EXIT="$meta_exit" A01_IGNORE_TERM="$ignore_term" \
        A01_TIMING_DIR="$folder" bash "$root/tests/a01.sh" --cenario "orcamento-$name" "$script" "$work" > "$folder/saida" 2>&1 || status=$?
    end="$(date +%s%N)"
    elapsed=$(((end - start) / 1000000))
    check test "$status" -eq "$expected"
    check grep -Fq 'Sequência de reinício/desligamento ordenado registrada.' "$folder/saida"
    check test "$elapsed" -ge 0
    # Folga de 2s para escalonamento/CI, alem dos 3s de -k no teste de KILL.
    check test "$elapsed" -le "$((budget * 1000 + ignore_term * 3000 + 2000))"
    check test "$(cat "$folder/dados-kill-after")" = 3s
    if [[ "$name" == esgotado ]]; then
        check test ! -f "$folder/metadados-inicio"
        check grep -Fq 'orçamento de tempo esgotado' "$folder/saida"
        grant=na gap=na
    else
        check test -f "$folder/metadados-inicio"
        grant="$(cat "$folder/metadados-limite")"
        gap=$((($(cat "$folder/metadados-inicio") - $(cat "$folder/dados-inicio")) / 1000000))
        # Confere o tempo concedido contra o consumo observado, nao so a duracao
        # total. A folga de 400ms cobre as chamadas de date e o escalonamento.
        check awk -v g="$grant" -v d="$gap" -v b="$budget" 'BEGIN {exit !(g > 0 && g*1000+d <= b*1000+400)}'
        check test "$(cat "$folder/metadados-kill-after")" = 3s
    fi
    if (( expected == 3 )); then check grep -Fq 'Coleta do journal (sistema): falha' "$folder/saida"; fi
    printf 'orcamento %-12s total_ms=%s dados_ate_meta_ms=%s meta_s=%s retorno=%s esperado=%s\n' \
        "$name" "$elapsed" "$gap" "$grant" "$status" "$expected"
}
run rapido       4 0.1 0.1 0   0 0 0
run significativo 4 1.5 0.2 0  0 0 0
run quase-todo   4 3.2 0.1 0   0 0 0
run esgotado     3 0.1 0.1 3.1 3 0 0
run excede-meta  3 2.2 1.3 0   3 0 0
run falha-meta   4 0.1 0.1 0   3 1 0
run kill-meta    2 0.1 10  0   3 0 1
clock_units() {
    # shellcheck source=../verifica-reinicio.sh
    source "$script"
    local name=relogio clock_value read_status=0 item expected output rc
    if ! declare -F tempo_monotonico_cs >/dev/null; then
        check declare -F tempo_monotonico_cs
        return
    fi
    check declare -F tempo_monotonico_cs
    # Simula somente a leitura para conferir formato/base decimal e falhas.
    # shellcheck disable=SC2317,SC2329
    read() { printf -v "$2" '%s' "$clock_value"; return "$read_status"; }
    for item in '0.00:0' '0008.09:809' '123.45:12345' '1.2:erro' '-1.00:erro' 'invalido:erro'; do
        clock_value="${item%:*}" expected="${item#*:}" rc=0
        output="$(tempo_monotonico_cs)" || rc=$?
        if [[ "$expected" == erro ]]; then
            check test "$rc" -eq 1
            check test -z "$output"
        else
            check test "$rc" -eq 0
            check test "$output" = "$expected"
        fi
    done
    read_status=1 rc=0
    output="$(tempo_monotonico_cs)" || rc=$?
    check test "$rc" -eq 1
    check test -z "$output"
    unset -f read
}
clock_units
printf 'Orcamento: %s verificacoes; %s falhas.\n' "$checks" "$failures"
(( failures == 0 ))
