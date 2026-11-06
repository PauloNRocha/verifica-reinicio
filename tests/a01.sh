#!/usr/bin/env bash
# A-01: integracao independente, journal/IPMI sinteticos e nenhum privilegio.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --cenario ]]; then
    export A01_SCENARIO="${2:?}"
    script="${3:?}"
    work="${4:?}"
    # shellcheck source=../verifica-reinicio.sh
    source "$script"
    # Conserva env/timeout reais, mas troca somente journalctl pela fixture lida
    # pelo Bash. Assim o laboratorio funciona tambem com /tmp montado noexec.
    # shellcheck disable=SC2317,SC2329
    env() {
        if [[ " $* " == *' journalctl '* ]]; then
            if [[ "${1:-}" != --default-signal=PIPE || "${2:-}" != timeout || "${3:-}" != -k || "${6:-}" != journalctl ]]; then
                echo 'ERRO: chamada journalctl fora do protocolo sintetico' >&2
                return 98
            fi
            if [[ -n "${A01_TIMING_DIR:-}" && " $* " == *' _PID=1 '* ]]; then
                local role=dados rc=0
                [[ " $* " != *' --output-fields=__CURSOR '* ]] || role=metadados
                printf '%s\n' "${5%s}" > "$A01_TIMING_DIR/$role-limite"
                printf '%s\n' "$4" > "$A01_TIMING_DIR/$role-kill-after"
                date +%s%N > "$A01_TIMING_DIR/$role-inicio"
                command env "$1" "$2" "$3" "$4" "$5" bash "$root/tests/fixtures/journalctl-a01.sh" "${@:7}" || rc=$?
                # Simula custo da captura apos a consulta, fora de timeout.
                if [[ "$role" == dados ]]; then sleep "${A01_POST_DATA_DELAY:-0}"; fi
                date +%s%N > "$A01_TIMING_DIR/$role-fim"
                return "$rc"
            fi
            command env "$1" "$2" "$3" "$4" "$5" bash "$root/tests/fixtures/journalctl-a01.sh" "${@:7}"
        else
            command env "$@"
        fi
    }
    # shellcheck disable=SC2317,SC2329
    journalctl() { echo 'ERRO: journalctl direto proibido' >&2; return 98; }
    # ShellCheck: os mocks sao acionados pelo main da ferramenta.
    # shellcheck disable=SC2317,SC2329
    requer_root() { :; }
    # shellcheck disable=SC2317,SC2329
    detecta_hostname() { HOSTNAME_RAW=host-exemplo; HOSTNAME_SAFE=host-exemplo; }
    # shellcheck disable=SC2317,SC2329
    mostra_info_sistema() { :; }
    # shellcheck disable=SC2317,SC2329
    mostra_boot_overview() { :; }
    # shellcheck disable=SC2317,SC2329
    mostra_linha_tempo() { :; }
    # shellcheck disable=SC2317,SC2329
    mostra_trecho_journal() { :; }
    # shellcheck disable=SC2317,SC2329
    verifica_crash_dumps() { :; }
    # shellcheck disable=SC2317,SC2329
    prepara_journal() {
        PREVIOUS_BOOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        BOOT_END_EPOCH=1768479660.000000
        BOOT_END_TS=2026-01-15T12:21:00.000000+00:00
        PREVIOUS_BOOT_START_EPOCH=1768470000
    }
    # shellcheck disable=SC2317,SC2329
    coleta_logs_aux() { :; }
    # shellcheck disable=SC2317,SC2329
    coleta_ipmi() {
        IPMI_CLOCK_OK=1
        CURRENT_BOOT_EPOCH=1768479720
        IPMI_SEL_NEAR="$(filtra_ipmi_proximo "$REF_TS" '0001 | 01/15/2026 | 12:21:30 UTC | Power Supply #0x01 | Power Supply AC lost | Asserted')"
        [[ "$A01_SCENARIO" == ipmi-* || "$A01_SCENARIO" == shutdown-oculto-* || "$A01_SCENARIO" == sem-message-* || "$A01_SCENARIO" == blob-* || "$A01_SCENARIO" == probe-* ]] || IPMI_SEL_NEAR=''
    }
    export PATH="$work/bin:$PATH"
    [[ "$A01_SCENARIO" != timeout-real-geral ]] || JOURNAL_TIMEOUT=1
    if [[ "$A01_SCENARIO" == orcamento-* ]]; then JOURNAL_TIMEOUT="${A01_BUDGET:?}"; fi
    # O teste altera apenas o modo; os limites 1500/8000/8MiB/30s sao os reais.
    if [[ "$A01_SCENARIO" == *-FAST ]]; then main --fast; else main --full; fi
    # main deve encerrar o processo; protege contra retorno inesperado futuro.
    # shellcheck disable=SC2317
    exit 99
fi

script="${1:-$root/verifica-reinicio.sh}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
for forbidden in journalctl ipmitool modprobe; do
    printf '#!/usr/bin/env bash\necho "ERRO: hardware real proibido" >&2\nexit 98\n' > "$work/bin/$forbidden"
    chmod 700 "$work/bin/$forbidden"
done
checks=0 failures=0
check() {
    checks=$((checks + 1))
    if ! "$@"; then failures=$((failures + 1)); printf 'FALHOU A-01: %s\n' "$scenario" >&2; fi
}
run() {
    scenario="$1"
    status=0
    bash "$root/tests/a01.sh" --cenario "$scenario" "$script" "$work" > "$work/result" 2>&1 || status=$?
    check test "$status" -eq "$2"
    check grep -Fq -- "$3" "$work/result"
    if [[ "${4:-}" != '' ]]; then
        checks=$((checks + 1))
        if grep -Fq -- "$4" "$work/result"; then failures=$((failures + 1)); echo "FALHOU A-01: $scenario contem $4" >&2; fi
    fi
    printf '%-42s retorno=%s esperado=%s\n' "$scenario" "$status" "$2"
}
run completo-sem-causa 2 'Reinício possivelmente abrupto'
run completo-ordenado 0 'Sequência de reinício/desligamento ordenado'
run completo-panic 0 'Evidência forte: Kernel panic'
run completo-request 0 'Solicitação de desligamento registrada'
run ipmi-completo 0 'Causa provável: Perda/instabilidade'
for mode in FAST FULL; do
    for kind in geral kernel sistema; do
        run "limite-$kind-$mode" 2 'coleta do journal incompleta' 'Reinício possivelmente abrupto'
        check grep -Fq -- "Coleta do journal ($kind): potencialmente incompleta" "$work/result"
        run "exato-$kind-$mode" 2 'coleta do journal incompleta' 'Reinício possivelmente abrupto'
        if [[ "$mode" == FULL ]]; then run "ipmi-$kind-$mode" 2 'coleta do journal incompleta' 'Causa provável:'; fi
    done
    run "shutdown-oculto-$mode" 2 'coleta do journal incompleta' 'Causa provável:'
    run "positivo-panic-kernel-$mode" 0 'Evidência forte: Kernel panic'
    run "positivo-ordenado-sistema-$mode" 0 'Sequência de reinício/desligamento ordenado'
    run "positivo-request-sistema-$mode" 0 'Solicitação de desligamento registrada'
    run "sem-message-$mode" 2 'coleta do journal incompleta' 'Causa provável:'
    run "blob-$mode" 2 'coleta do journal incompleta' 'Causa provável:'
    run "multiline-$mode" 2 'Reinício possivelmente abrupto' 'coleta do journal incompleta'
done
run positivo-com-geral-truncado-FULL 0 'Sequência de reinício/desligamento ordenado'
run positivo-com-kernel-truncado-FULL 0 'Sequência de reinício/desligamento ordenado'
run falha-kernel-com-ordenado 3 'Sequência de reinício/desligamento ordenado'
run timeout-real-geral 3 'falha ou timeout' 'Causa provável:'
run probe-falha-kernel-com-panic 3 'Evidência forte: Kernel panic'
run probe-timeout-sistema-com-ordenado 3 'Sequência de reinício/desligamento ordenado'
for kind in geral kernel sistema; do
    run "falha-$kind" 3 'falha ou timeout' 'Evidência forte:'
    run "timeout-$kind" 3 'falha ou timeout' 'Evidência forte:'
    run "bytes-$kind" 3 'bytes excedido' 'Evidência forte: Kernel panic'
    check grep -Fq -- "Coleta do journal ($kind): truncada por bytes" "$work/result"
    run "probe-falha-$kind" 3 'completude' 'Causa provável:'
    run "probe-timeout-$kind" 3 'completude' 'Causa provável:'
    run "probe-bytes-$kind" 2 'coleta do journal incompleta' 'Causa provável:'
done
printf 'A-01: %s verificacoes; %s falhas.\n' "$checks" "$failures"
(( failures == 0 ))
