#!/usr/bin/env bash
# Executado em processo independente: nao envolver main em if/&&/||.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cenario="${1:?Informe o cenario sintetico}"
work="${2:?Informe o diretorio temporario dos testes}"
# shellcheck source=../verifica-reinicio.sh
source "$root/verifica-reinicio.sh"

# Todos os acessos a dados do host/hardware sao substituidos antes de chamar main.
# shellcheck disable=SC2329
requer_root() { :; }
# shellcheck disable=SC2329
detecta_hostname() { HOSTNAME_RAW=host-exemplo; HOSTNAME_SAFE=host-exemplo; }
# shellcheck disable=SC2329
mostra_info_sistema() { :; }
# shellcheck disable=SC2329
mostra_boot_overview() { echo 'HISTORICO_DE_BOOTS'; }
# shellcheck disable=SC2329
mostra_linha_tempo() { :; }
# shellcheck disable=SC2329
verifica_crash_dumps() { :; }
# shellcheck disable=SC2329
prepara_journal() { :; }
# shellcheck disable=SC2329
coleta_journal_boot_anterior() {
    [[ -z "$SAVE_FILE" ]] || printf '%s\n' "$SAVE_FILE" > "$work/path"
    echo '2026-01-15T12:21:00Z host-exemplo app: relatorio sintetico'
}
# shellcheck disable=SC2329
coleta_journal_kernel_boot_anterior() { :; }
# shellcheck disable=SC2329
coleta_journal_sistema_boot_anterior() { :; }
# shellcheck disable=SC2329
coleta_logs_aux() { :; }
# shellcheck disable=SC2329
coleta_ipmi() { :; }

args=(--fast)
case "$cenario" in
    fast)
        coleta_logs_aux() { echo 'FAST consultou logs auxiliares' >&2; exit 99; }
        coleta_ipmi() { echo 'FAST consultou IPMI' >&2; exit 99; }
        ;;
    ordem) args=(--full) ;;
    save) args+=(--save) ;;
    mktemp)
        args+=(--save)
        mktemp() { return 1; }
        ;;
    tee)
        args+=(--save)
        tee() { cat > /dev/null; return 1; }
        ;;
    inconsistent-main)
        # Mantem a coleta real, mas substitui o comando externo por saida vazia.
        unset -f coleta_journal_boot_anterior
        # shellcheck source=../verifica-reinicio.sh
        source "$root/verifica-reinicio.sh"
        requer_root() { :; }
        detecta_hostname() { HOSTNAME_RAW=host-exemplo; HOSTNAME_SAFE=host-exemplo; }
        mostra_info_sistema() { :; }
        mostra_boot_overview() { :; }
        mostra_linha_tempo() { :; }
        prepara_journal() {
            BOOT_END_EPOCH=1768479660.000000
            BOOT_END_TS=2026-01-15T12:21:00Z
            PREVIOUS_BOOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        }
        # shellcheck disable=SC2329
        timeout() { shift 3; "$@"; }
        # shellcheck disable=SC2329
        env() { shift; "$@"; }
        # shellcheck disable=SC2329
        journalctl() { :; }
        ;;
    full)
        args=(--full)
        coleta_journal_boot_anterior() { :; }
        coleta_logs_aux() { echo 'old kernel: Kernel panic'; }
        ;;
    erro-inesperado)
        mostra_info_sistema() { false; echo 'ERRO_IGNORADO'; }
        ;;
    sistema-falhou)
        coleta_journal_sistema_boot_anterior() { return 3; }
        ;;
    env-incompativel)
        env() { return 125; }
        ;;
    ordenado)
        coleta_journal_sistema_boot_anterior() {
            echo '2026-01-15T12:21:00Z host-exemplo systemd[1]: Reached target poweroff.target - System Power Off.'
        }
        ;;
    origem-nao-confiavel)
        coleta_journal_boot_anterior() {
            echo '2026-01-15T12:21:00Z host-exemplo app[42]: quoted: systemd[1]: Reached target poweroff.target - example'
            echo '2026-01-15T12:21:01Z host-exemplo systemd[1]: Reached target poweroff.target - tag fornecida pelo aplicativo'
        }
        ;;
    *) echo "Cenario desconhecido: $cenario" >&2; exit 1 ;;
esac
main "${args[@]}"
