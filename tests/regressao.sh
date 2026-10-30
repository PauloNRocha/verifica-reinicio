#!/usr/bin/env bash
# Cenários sintéticos com hostnames, sensores e identificadores fictícios. Não consulta journal/IPMI real nem carrega módulos.
# Mocks chamados via wrappers/timeout: SC2317 (0.9/0.10) e SC2329 (0.11).
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../verifica-reinicio.sh
source "$root/verifica-reinicio.sh"
init_colors
# Permite mocks de comandos em funcao sem exporta-los ao ambiente. Comandos
# reais continuam usando env e sua normalizacao de SIGPIPE, como em producao.
# shellcheck disable=SC2317,SC2329
env() {
    if [[ "${1:-}" == '--default-signal=PIPE' && "$(type -t "${2:-}" || true)" == function ]]; then
        shift
        "$@"
    else
        command env "$@"
    fi
}
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
checks=0
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf 'FALHOU: %s (esperado %s, recebido %s)\n' "$3" "$2" "$1" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
assert_has() {
    if ! grep -Fq -- "$2" <<< "$1"; then
        printf 'FALHOU: %s\n' "$3" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
assert_lacks() {
    if grep -Fq -- "$2" <<< "$1"; then
        printf 'FALHOU: %s\n' "$3" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
analyze() {
    EXIT_CODE=0
    # Nas unidades, o quinto argumento representa a coleta de origem confiavel.
    analisa_reinicio "$1" "$2" "$3" "$4" "${5-$1}" > "$work/result"
    result="$(cat "$work/result")"
}
end='2026-02-04T12:21:20.500000-03:00'
REF_TS="$end"
PREVIOUS_BOOT_START_EPOCH="$(date -d '2026-02-04T10:00:00-03:00' +%s)"
log="$end host-exemplo pvedaemon[2062]: successful auth"
acpi='2026-02-04T12:21:20.400000-03:00 host-exemplo systemd-logind[800]: Power key pressed short'
shutdown="$end host-exemplo systemd-shutdown[1]: Powering off."
assert_eq "$(extrai_shutdown_ts "$shutdown")" "$end" 'timestamp sem hostname e com microssegundos'
analyze "$log" '' '' ''
assert_eq "$EXIT_CODE" 2 'abrupto sem causa continua inconclusivo'
assert_has "$result" 'Reinício possivelmente abrupto' 'restaura sinal observado na 1.2.4'
assert_has "$result" 'Causa não determinada.' 'abrupto não confirma energia'
# A mensagem principal deve se destacar no terminal e continuar limpa em pipes.
C_RED=$'\e[31m'
C_YELLOW=$'\e[33m'
C_BOLD=$'\e[1m'
C_RESET=$'\e[0m'
analyze "$log" '' '' ''
assert_has "$result" $'\e[1m\e[31mReinício possivelmente abrupto:' 'alerta vermelho no terminal'
assert_has "$result" $'\e[1m\e[33mCausa não determinada.' 'incerteza amarela no terminal'
init_colors
analyze "$log" '' '' ''
if [[ "$result" == *$'\e['* ]]; then
    echo 'FALHOU: ANSI em saída sem TTY' >&2
    exit 1
fi
checks=$((checks + 1))
analyze '' '' '' ''
assert_eq "$EXIT_CODE" 2 'sem registros'
if grep -Fq 'Reinício possivelmente abrupto' <<< "$result"; then
    echo 'FALHOU: não há base para inferir abrupto sem journal' >&2
    exit 1
fi
checks=$((checks + 1))
analyze "$log" '' 'Dec 29 kernel: Kernel panic - old' ''
assert_eq "$EXIT_CODE" 2 'panic histórico não determina reboot'
assert_has "$result" 'Indícios históricos' 'histórico identificado'
analyze "$log" '' '' '0004 | 02/04/2026 | 12:21:00 | Power Supply #0x01 | Power Supply AC lost | Deasserted'
assert_eq "$EXIT_CODE" 2 'recuperação IPMI não é perda ativa'
MODE=FULL
IPMI_CLOCK_OK=0
IPMI_SEL_LIST='0006 | 02/04/2026 | 11:00:00 -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
analyze "$log" '' '' ''
assert_eq "$EXIT_CODE" 2 'divergência BMC não transforma indício em causa'
assert_has "$result" 'Reinício possivelmente abrupto' 'abrupto mantém destaque no FULL'
assert_has "$result" 'Indício elétrico:' 'SEL com relógio divergente é indício'
C_YELLOW=$'\e[33m'
C_BOLD=$'\e[1m'
C_RESET=$'\e[0m'
analyze "$log" '' '' ''
assert_has "$result" $'\e[1m\e[33mIndício elétrico:' 'indício destacado sem apresentar como causa'
init_colors
IPMI_SEL_LIST='0007 | 02/04/2026 | 11:00:00 -03 | Power Supply #0x01 | Power Supply AC lost | Deasserted'
analyze "$log" '' '' ''
if grep -Fq 'Indício elétrico:' <<< "$result"; then
    echo 'FALHOU: apenas Deasserted não estabelece perda AC' >&2
    exit 1
fi
checks=$((checks + 1))
IPMI_SEL_LIST=''
MODE=FAST
analyze "$log" '' '' '0004 | 02/04/2026 | 12:21:00 | Power Supply #0x01 | Fully Redundant | Asserted'
assert_eq "$EXIT_CODE" 2 'redundância normal não é falha'
sel='0003 | 02/04/2026 | 12:28:24 PM -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
analyze "$acpi" '' '' "$sel"
assert_eq "$EXIT_CODE" 0 'energia correlacionada com ACPI'
assert_has "$result" 'Causa provável: Perda/instabilidade' 'classificação elétrica'
assert_has "$result" 'Evento da tecla de energia registrado' 'preserva evidência da tecla de energia'
analyze "$acpi" '' '' ''
assert_eq "$EXIT_CODE" 2 'tecla isolada não confirma desligamento'
assert_has "$result" 'Evento da tecla de energia registrado' 'evento explícito continua visível'
analyze "$shutdown" '' '' ''
assert_eq "$EXIT_CODE" 0 'sequência final registrada'
# Solicitações genéricas não identificam tecla, terminal, menu ou falha elétrica.
for msg in 'System is powering down.' 'Powering off...'; do
    request_log="$end host-exemplo systemd-logind[800]: $msg"
    analyze "$request_log" '' '' ''
    assert_eq "$EXIT_CODE" 0 "solicitação genérica registrada: $msg"
    assert_has "$result" 'Solicitação de desligamento registrada pelo sistema.' 'logind genérico não é ACPI'
    assert_lacks "$result" 'Power key' 'não inventa evento da tecla de energia'
    assert_lacks "$result" 'glitch' 'não sugere glitch sem evidência elétrica'
    assert_lacks "$result" 'ordenado registrada' 'solicitação isolada não é sequência final'
done
# Sequência sintética equivalente a um poweroff pelo terminal ou menu.
ordered_log="$request_log"$'\n'"$end host-exemplo systemd[1]: Reached target poweroff.target - System Power Off."
ordered_log+=$'\n'"$end host-exemplo systemd[1]: Shutting down."
ordered_log+=$'\n'"$end host-exemplo systemd-shutdown[1]: Syncing filesystems and block devices."
ordered_log+=$'\n'"$end host-exemplo systemd-shutdown[1]: Sending SIGTERM to remaining processes..."
ordered_log+=$'\n'"$end host-exemplo systemd-journald[100]: Journal stopped"
for mode in FAST FULL; do
    MODE="$mode"
    analyze "$ordered_log" '' '' ''
    assert_eq "$EXIT_CODE" 0 "$mode reconhece desligamento ordenado"
    assert_has "$result" 'Sequência de reinício/desligamento ordenado registrada.' "$mode destaca a sequência registrada"
    assert_lacks "$result" 'Power key' "$mode não atribui poweroff à tecla de energia"
    assert_lacks "$result" 'glitch' "$mode não associa desligamento normal a falha elétrica"
done
MODE=FAST
analyze "$ordered_log"$'\n'"$acpi" '' '' ''
assert_eq "$EXIT_CODE" 0 'tecla e sequência ordenada podem coexistir'
assert_has "$result" 'Evento da tecla de energia registrado' 'evidência da tecla é separada da sequência'
for target in poweroff reboot halt; do
    target_log="$end host-exemplo systemd[1]: Reached target $target.target - description."
    analyze "$target_log" '' '' ''
    assert_eq "$EXIT_CODE" 0 "target final reconhecido: $target"
    assert_eq "$(extrai_shutdown_ts "$target_log")" "$end" "linha do tempo inclui $target.target"
done
analyze "$end host-exemplo systemd[1]: Reached target poweroff.target-extra - example." '' '' ''
assert_eq "$EXIT_CODE" 2 'target de nome semelhante não é sequência final'
analyze "$end host-exemplo systemd-shutdown[1]: Sending SIGTERM to remaining processes..." '' '' ''
assert_eq "$EXIT_CODE" 2 'etapa intermediária isolada não confirma sequência final'
for msg in 'NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.' 'Out of memory: Killed process 12 (java)' 'Memory cgroup out of memory' 'BUG: soft lockup - CPU#1' 'segfault at 0' 'Oops: 0000' 'hung_task: blocked'; do
    analyze "$log" "$end host-exemplo kernel: $msg" '' ''
    assert_eq "$EXIT_CODE" 2 "evento isolado: $msg"
done
analyze "$log" "$end host-exemplo kernel: Kernel panic - not syncing" '' ''
assert_eq "$EXIT_CODE" 0 'panic explícito'
for msg in 'Started unattended-upgrades.service - Unattended Upgrades Shutdown.' 'Started apcupsd.service.' 'Power Supply fully redundant'; do
    analyze "$end host-exemplo systemd[1]: $msg" '' '' ''
    assert_eq "$EXIT_CODE" 2 "mensagem normal: $msg"
done
analyze "$shutdown"$'\n'"$end host-exemplo systemd[1]: Started unattended-upgrades.service - Unattended Upgrades Shutdown." '' '' ''
if grep -qi 'causado por atualização' <<< "$result"; then exit 1; fi
checks=$((checks + 1))
IPMI_CLOCK_OK=1
CURRENT_BOOT_EPOCH="$(date -d '2026-02-04T12:29:45-03:00' +%s)"
near="$(filtra_ipmi_proximo "$end" "$sel")"
assert_eq "$near" "$sel" 'caso host-exemplo: último log 12:21 e SEL 12:28'
old='0001 | 02/03/2026 | 09:00:16 PM -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
after='0005 | 02/04/2026 | 12:30:00 PM -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo "$end" "$old"$'\n'"$after")" '' 'exclui eventos antigos e posteriores ao boot'
IPMI_CLOCK_OK=0
assert_eq "$(filtra_ipmi_proximo "$end" "$sel")" '' 'relógio não validado impede correlação'
# Grande volume de evidências não deve causar SIGPIPE.
large="$(awk 'BEGIN {for(i=0;i<20000;i++) print "2026-02-04T12:21:20-03:00 host-exemplo kernel: Kernel panic - not syncing"}')"
analyze "$log" "$large" '' ''
assert_eq "$EXIT_CODE" 0 'muitas evidências não interrompem análise'
# Coleta simulada: horário fracionário precisa chegar intacto a --until.
BOOT_END_EPOCH='1770218480.500000'
BOOT_END_TS="$end"
PREVIOUS_BOOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# Mock chamado indiretamente por timeout.
# shellcheck disable=SC2317,SC2329
journalctl() { printf '%s\n' "$*" > "$work/args"; printf '%s\n' "$log"; }
# shellcheck disable=SC2317,SC2329
timeout() { shift 3; "$@"; }
coleta_journal_boot_anterior > "$work/journal"
assert_has "$(cat "$work/args")" '--until @1770218480.500000' 'preserva fração no limite superior'
assert_has "$(cat "$work/args")" '--since @1770216680' 'janela de 30 minutos'
assert_has "$(cat "$work/args")" '-n 1500' 'limite FAST'
MODE=FULL
coleta_journal_kernel_boot_anterior > "$work/journal"
assert_has "$(cat "$work/args")" '-k' 'coleta kernel separada'
assert_has "$(cat "$work/args")" '-n 8000' 'limite FULL'
unset -f journalctl timeout
# CLI e códigos sem executar coleta real.
status=0
bash "$root/verifica-reinicio.sh" --help > /dev/null || status=$?
assert_eq "$status" 0 'ajuda'
status=0
bash "$root/verifica-reinicio.sh" --invalido > /dev/null 2>&1 || status=$?
assert_eq "$status" 1 'argumento inválido'
# Processos novos preservam errexit/ERR; condicionar o processo pai e seguro.
run_case() {
    status=0
    bash "$root/tests/integracao.sh" "$1" "$work" > "$work/$1" 2>&1 || status=$?
}
run_case fast
assert_eq "$status" 2 'FAST isolado termina inconclusivo sem consultas FULL'
run_case ordem
assert_eq "$status" 2 'ordem de saída mantém código inconclusivo'
if ! awk '/Reinício possivelmente abrupto:/ {resultado=NR} /HISTORICO_DE_BOOTS/ {historico=NR} END {exit !(resultado > 0 && historico > resultado)}' "$work/ordem"; then
    echo 'FALHOU: histórico de boots apareceu antes do resultado' >&2
    exit 1
fi
checks=$((checks + 1))
run_case save
assert_eq "$status" 2 'salvar preserva código inconclusivo'
report="$(cat "$work/path")"
assert_eq "$(stat -c %a "$report")" 600 'permissão privada'
assert_has "$(cat "$report")" 'relatorio sintetico' 'gravação finalizada'
rm -- "$report"
run_case mktemp
assert_eq "$status" 3 'falha mktemp sem fallback inseguro'
run_case tee
assert_eq "$status" 3 'falha tee é erro de execução'
rm -- "$(cat "$work/path")"
run_case erro-inesperado
assert_eq "$status" 3 'ERR encerra processo independente'
assert_lacks "$(cat "$work/erro-inesperado")" 'ERRO_IGNORADO' 'errexit nao e desativado pelo teste'
run_case sistema-falhou
assert_eq "$status" 3 'falha na coleta confiavel permanece erro'
run_case env-incompativel
assert_eq "$status" 3 'env sem suporte a sinais e erro de requisito'
assert_has "$(cat "$work/env-incompativel")" 'GNU env' 'requisito ausente e explicado antes da coleta'
run_case ordenado
assert_eq "$status" 0 'main reconhece sequencia da coleta confiavel'
run_case origem-nao-confiavel
assert_eq "$status" 2 'main nao confia em tags ou citacoes do journal geral'
assert_lacks "$(cat "$work/origem-nao-confiavel")" 'ordenado registrada' 'texto nao vira origem confiavel'
# Conversões SEL: meia-noite, meio-dia, offset e formato inválido.
assert_eq "$(epoch_ipmi '02/04/2026 12:00:00 AM -03')" "$(date -d '2026-02-04T00:00:00-03:00' +%s)" 'SEL meia-noite'
assert_eq "$(epoch_ipmi '02/04/2026 12:00:00 PM -03')" "$(date -d '2026-02-04T12:00:00-03:00' +%s)" 'SEL meio-dia'
assert_eq "$(epoch_ipmi '02/04/2026 15:28:24 +0000')" "$(date -d '2026-02-04T15:28:24Z' +%s)" 'SEL 24 horas UTC'
assert_eq "$(epoch_ipmi 'Pre-Init Time-stamp')" '' 'SEL sem data'
assert_eq "$(epoch_ipmi '02/31/2026 12:00:00 PM -03')" '' 'SEL data inválida'
IPMI_CLOCK_OK=1
CURRENT_BOOT_EPOCH="$(date -d '2026-02-05T12:29:45-03:00' +%s)"
assert_eq "$(filtra_ipmi_proximo "$end" "$sel")" '' 'intervalo grande exige investigação manual'
CURRENT_BOOT_EPOCH="$(date -d '2026-02-04T12:29:45-03:00' +%s)"
# Prepara journal com listagem sintética, mantendo o boot atual real apenas como âncora.
mock_current_id="$(tr -d '-' < /proc/sys/kernel/random/boot_id)"
mock_current_id="${mock_current_id//$'\n'/}"
# shellcheck disable=SC2317,SC2329
timeout() { shift 3; "$@"; }
# shellcheck disable=SC2317,SC2329
journalctl() {
    printf '%s\n' "$*" > "$work/args"
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    else
        printf '%s\n' '__REALTIME_TIMESTAMP=1770218480500000' '_SOURCE_REALTIME_TIMESTAMP=1770218480498897'
    fi
}
prepara_journal
assert_eq "$BOOT_END_EPOCH" '1770218480.500000' 'referência obtida com microssegundos'
assert_eq "$PREVIOUS_BOOT_ID" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 'fixa ID do boot'
assert_has "$(cat "$work/args")" '-o export --output-fields=__REALTIME_TIMESTAMP' 'referência usa metadado de recebimento'
# Um único registro no fim da janela: a origem antecede o recebimento em 1103 us.
# A consulta antiga o excluía, embora o histórico mostrasse o boot anterior.
# shellcheck disable=SC2317,SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    elif [[ " $* " == *' -o export '* ]]; then
        printf '%s\n' '__REALTIME_TIMESTAMP=1770218480501103' '_SOURCE_REALTIME_TIMESTAMP=1770218480500000'
    elif [[ " $* " == *' -o short-unix '* ]]; then
        printf '%s\n' '1770218480.500000 host-exemplo app: last record'
    else
        local lower=0 upper=0 kernel_only=0
        while (( $# )); do
            case "$1" in
                --since) lower="${2#@}"; lower=$((lower * 1000000)); shift ;;
                --until) upper="${2#@}"; upper="${upper/./}"; shift ;;
                -k) kernel_only=1 ;;
            esac
            shift
        done
        if (( ! kernel_only && lower <= 1770218480501103 && upper >= 1770218480501103 )); then
            printf '%s\n' "$log"
        fi
    fi
    return 0
}
assert_eq "$(journalctl --since @1770216680 --until @1770218480.500000)" '' 'limite de origem reproduz coleta vazia'
prepara_journal
assert_eq "$BOOT_END_EPOCH" '1770218480.501103' 'recebimento difere do horário de origem'
for mode in FAST FULL; do
    MODE="$mode"
    collected="$(coleta_journal_boot_anterior)"
    assert_eq "$collected" "$log" "$mode conserva o último registro com atraso de recebimento"
    analyze "$collected" '' '' ''
    assert_has "$result" 'Reinício possivelmente abrupto' "$mode não confunde filtro vazio com journal ausente"
    assert_eq "$EXIT_CODE" 2 "$mode continua sem atribuir causa elétrica"
    coleta_journal_kernel_boot_anterior > "$work/kernel" && status=0 || status=$?
    assert_eq "$status" 0 "$mode aceita ausência de eventos de kernel na janela"
    assert_eq "$(cat "$work/kernel")" '' "$mode não amplia janela para buscar kernel antigo"
done
# Coleta geral vazia após referência válida é erro, não ausência normal de journal.
# shellcheck disable=SC2317,SC2329
journalctl() { :; }
coleta_journal_boot_anterior > "$work/empty" 2> "$work/empty-error" && status=0 || status=$?
assert_eq "$status" 3 'consulta geral inconsistente retorna erro'
assert_has "$(cat "$work/empty-error")" 'consulta temporal do journal retornou vazia' 'aviso específico para coleta inconsistente'
EXIT_CODE=3
analisa_reinicio '' '' '' '' > "$work/result"
assert_has "$(cat "$work/result")" 'Análise indisponível:' 'não declara inexistência de logs após erro'
EXIT_CODE=0
run_case inconsistent-main
assert_eq "$status" 3 'main propaga inconsistência da consulta geral'
assert_has "$(cat "$work/inconsistent-main")" 'Análise indisponível:' 'resultado distingue falha de coleta na execução completa'
# A conversão usa aritmética inteira e conserva zeros nos microssegundos.
# shellcheck disable=SC2317,SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    else
        printf '%s\n' '__REALTIME_TIMESTAMP=1770218480001103'
    fi
}
prepara_journal
assert_eq "$BOOT_END_EPOCH" '1770218480.001103' 'conversão preserva zeros nos microssegundos'
# shellcheck disable=SC2317,SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    else
        printf '%s\n' 'invalid timestamp'
    fi
}
prepara_journal
assert_eq "$BOOT_END_EPOCH" '' 'referência inválida não libera consulta sem janela'
assert_eq "$EXIT_CODE" 3 'metadado inválido é erro de coleta'
assert_eq "$(coleta_journal_boot_anterior)" '' 'não coleta sem referência válida'
# Um timestamp de origem isolado nunca substitui o metadado de recebimento.
# shellcheck disable=SC2317,SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    else
        printf '%s\n' '_SOURCE_REALTIME_TIMESTAMP=1770218480500000'
    fi
}
prepara_journal
assert_eq "$BOOT_END_EPOCH" '' 'não usa timestamp de origem como fallback'
unset -f journalctl timeout
# Ausência de journalctl: não confundir com evidência de falha elétrica.
(
    # Mock consultado indiretamente pela coleta.
    # shellcheck disable=SC2317,SC2329
    command() {
        if [[ "$*" == '-v journalctl' ]]; then return 1; fi
        builtin command "$@"
    }
    BOOT_END_EPOCH=''
    prepara_journal
    [[ -z "$BOOT_END_EPOCH" ]]
) > "$work/missing" 2>&1
assert_has "$(cat "$work/missing")" 'journalctl não encontrado' 'degrada sem journalctl'
# Falha no journal é distinguida de ausência de evidências.
BOOT_END_EPOCH='1770218480.500000'
# shellcheck disable=SC2317,SC2329
timeout() { return 124; }
coleta_journal_boot_anterior > /dev/null 2>&1 && status=0 || status=$?
assert_eq "$status" 3 'timeout journal retorna erro'
unset -f timeout
EXIT_CODE=3
analisa_reinicio "$shutdown" '' '' '' > /dev/null
assert_eq "$EXIT_CODE" 3 'evidência não oculta erro de coleta'
# FULL sem journal ainda fornece indícios históricos, mas não confirma causa.
run_case full
assert_eq "$status" 2 'FULL só histórico permanece inconclusivo'
assert_has "$(cat "$work/full")" 'old kernel: Kernel panic' 'FULL mantém histórico visível'
# Falhas opcionais do BMC: simula timeout e relógio divergente.

# Apenas presença do comando: timeout simulado fornece o resultado.
# shellcheck disable=SC2317,SC2329
ipmitool() { :; }
# shellcheck disable=SC2317,SC2329
modprobe() { :; }
timeout() {
    case "$*" in
        *'sel time get') echo '02/04/2026 12:45:39 PM -03' ;;
        *'sel list last 50') printf '%s\n' "$sel"; return 124 ;;
    esac
}
coleta_ipmi 2> "$work/ipmi"
assert_eq "$IPMI_AVAILABLE" 0 'timeout SEL não indica disponibilidade'
assert_eq "$IPMI_SEL_LIST" '' 'descarta SEL parcial'
timeout() {
    case "$*" in
        *'sel time get') echo '01/01/2000 12:00:00 AM -03' ;;
        *'sel list last 50') printf '%s\n' "$sel" ;;
    esac
}
coleta_ipmi 2> "$work/ipmi"
assert_eq "$IPMI_AVAILABLE" 1 'SEL acessível'
assert_eq "$IPMI_CLOCK_OK" 0 'relógio divergente'
assert_eq "$IPMI_SEL_NEAR" '' 'não classifica SEL com relógio divergente'
unset -f ipmitool modprobe timeout
# Regressão do FULL no Ubuntu: mensagens normais não são indícios.
noise="$(cat <<'LOG'
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: Adding input device Power Button (/dev/input/event1)
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: Power Button: Applying InputClass libinput keyboard catchall
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: Power Button: always reports core events
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: event1 - Power Button: device removed
2026-09-18T12:32:09-03:00 host-exemplo systemd[1]: anacron.service skipped (ConditionACPower=true).
2026-09-18T12:46:25-03:00 host-exemplo systemd[1]: Stopping cups-browsed.service - Make remote CUPS printers available locally...
2026-09-19T09:47:48-03:00 host-exemplo kernel: ftrace: allocated 228 pages with 4 groups
2026-09-19T09:47:48-03:00 host-exemplo kernel: CPU0: Thermal monitoring enabled (TM1)
2026-09-19T09:47:48-03:00 host-exemplo kernel: thermal_sys: Registered thermal governor power_allocator
2026-09-19T09:47:48-03:00 host-exemplo kernel: ACPI: New power resource
2026-09-19T09:47:48-03:00 host-exemplo kernel: thermal thermal_zone10: failed to read out thermal zone (-61)
2026-09-19T09:47:48-03:00 host-exemplo systemd[1]: Reached target nss-lookup.target - Host and Network Name Lookups.
2026-09-19T09:47:48-03:00 host-exemplo systemd[1]: Starting thermald.service - Thermal Daemon Service...
2026-09-19T09:47:48-03:00 host-exemplo systemd[1]: Starting power-profiles-daemon.service - Power Profiles daemon...
2026-09-19T09:47:48-03:00 host-exemplo kernel: NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.
LOG
)"
assert_eq "$(filtra_indicios "$noise")" '' 'ignora mensagens normais fornecidas pelo usuário'
for event in 'Kernel panic - not syncing' 'BUG: soft lockup - CPU#1 stuck for 26s' 'NMI watchdog: Watchdog detected hard LOCKUP' 'Out of memory: Killed process 123 (java)' 'critical temperature reached (100 C), shutting down' 'I/O error, dev sda' 'Hardware Error: Machine Check Exception' 'segfault at 0' 'Power failure detected' 'Power Supply AC lost' 'UPS on battery'; do
    event_line="2026-09-21T08:54:35-03:00 host-exemplo kernel: $event"
    assert_eq "$(filtra_indicios "$noise"$'\n'"$event_line")" "$event_line" "preserva evento: $event"
done
assert_eq "$(filtra_indicios "$acpi")" "$acpi" 'preserva logind Power key realmente pressionada'
EXIT_CODE=0
analyze "$log" "$noise" '' ''
assert_eq "$EXIT_CODE" 2 'ruído térmico não determina causa'
if grep -Fq 'Indícios do kernel' <<< "$result"; then
    echo 'FALHOU: cabeçalho de indícios para kernel normal' >&2
    exit 1
fi
checks=$((checks + 1))
mkdir "$work/logs"
printf '%s\n' "$noise" > "$work/logs/syslog"
: > "$work/logs/kern.log"
assert_eq "$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")" '' 'sem cabeçalhos vazios nos logs históricos'
assert_has "$(cat "$work/aux-warnings")" 'Nenhum evento relevante encontrado' 'resumo quando amostras não contêm eventos'
printf '%s\n' "$noise" "$acpi" > "$work/logs/syslog"
history="$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")"
assert_has "$history" "$acpi" 'coleta preserva ocorrência histórica relevante'
if grep -Eq 'kern.log|Power Button|CUPS|groups|Thermal monitoring' <<< "$history"; then
    echo 'FALHOU: ruído ou cabeçalho vazio na coleta histórica' >&2
    exit 1
fi
checks=$((checks + 1))
if command -v gzip >/dev/null 2>&1; then
    printf '%s\n' "$noise" | gzip > "$work/logs/syslog.1.gz"
    history="$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")"
    if grep -Fq 'syslog.1.gz' <<< "$history"; then exit 1; fi
    checks=$((checks + 1))
    printf '%s\n' "$noise" "$acpi" | gzip > "$work/logs/syslog.1.gz"
    history="$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")"
    assert_has "$history" 'syslog.1.gz' 'arquivo comprimido aparece se contém ocorrência'
fi
touchpad='2026-09-21T09:36:11.709643-03:00 host-exemplo /usr/libexec/gdm-x-session[4769]: (EE) event4 - Example Touchpad: kernel bug: Touch jump detected and discarded.'
assert_eq "$(filtra_indicios "$touchpad")" '' 'libinput não é BUG emitido pelo kernel'
kernel_bug='2026-09-21T09:36:11-03:00 host-exemplo kernel: BUG: unable to handle page fault'
assert_eq "$(filtra_indicios "$kernel_bug")" "$kernel_bug" 'mantém BUG emitido pelo kernel'
# Regressão host-exemplo: SEL MM/DD/YY e diferença de relógio explícita.
assert_eq "$(epoch_ipmi '01/15/26 09:00:00 -03')" "$(date -d '2026-01-15T09:00:00-03:00' +%s)" 'ano curto e offset'
assert_eq "$(epoch_ipmi '01/15/26 09:00:00 AM -03')" "$(epoch_ipmi '01/15/2026 09:00:00 AM -03')" 'ano curto AM/PM'
assert_eq "$(epoch_ipmi '01/01/68 00:00:00 UTC')" "$(date -d '2068-01-01T00:00:00Z' +%s)" 'limite superior século 2000'
assert_eq "$(epoch_ipmi '01/01/69 00:00:00 UTC')" "$(date -d '1969-01-01T00:00:00Z' +%s)" 'limite inferior século 1900'
assert_eq "$(epoch_ipmi '02/30/26 09:00:00 -03')" '' 'ano curto não aceita data inválida'
assert_eq "$(epoch_ipmi '01/15/026 09:00:00 -03')" '' 'rejeita ano de três dígitos'
host_epoch="$(date -d '2026-01-15T12:00:00-03:00' +%s)"
valida_relogio_ipmi '01/15/26 09:00:00 -03' "$host_epoch" 2> "$work/clock"
assert_eq "$IPMI_CLOCK_OK" 0 'três horas de atraso impedem correlação'
assert_eq "$IPMI_CLOCK_DELTA" 10800 'diferença em segundos'
assert_has "$(cat "$work/clock")" 'atrasado 10800 segundos' 'aviso de divergência, não de parse'
if grep -q 'sem fuso explícito' "$work/clock"; then exit 1; fi
checks=$((checks + 1))
valida_relogio_ipmi '01/15/26 12:00:00 -03' "$host_epoch" 2> "$work/clock"
assert_eq "$IPMI_CLOCK_OK" 1 'ano curto sincronizado permite correlação'
assert_eq "$IPMI_CLOCK_DELTA" 0 'relógios sincronizados'
valida_relogio_ipmi '01/15/26 15:00:00 -03' "$host_epoch" 2> "$work/clock"
assert_has "$(cat "$work/clock")" 'adiantado 10800 segundos' 'direção da diferença'
valida_relogio_ipmi 'data inválida' "$host_epoch" 2> "$work/clock"
assert_eq "$IPMI_CLOCK_DELTA" '' 'parse inválido não fabrica diferença'
assert_has "$(cat "$work/clock")" 'não interpretável' 'aviso específico de parse'
valida_relogio_ipmi '01/15/26 12:00:00' "$host_epoch" 2> "$work/clock"
assert_has "$(cat "$work/clock")" 'sem fuso explícito' 'aviso apenas se falta offset'
IPMI_CLOCK_OK=1
CURRENT_BOOT_EPOCH="$(date -d '2026-01-15T11:00:00-03:00' +%s)"
PREVIOUS_BOOT_START_EPOCH="$(date -d '2026-01-15T09:00:00-03:00' +%s)"
short_sel='0002 | 01/15/26 | 10:58:00 -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo '2026-01-15T10:55:00.500000-03:00' "$short_sel")" "$short_sel" 'correlação SEL ano curto'
old_sel='0001 | 01/15/26 | 09:30:00 -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo '2026-01-15T10:55:00.500000-03:00' "$old_sel")" '' 'evento sintético fora da janela não está na janela'

# Regressao: proximidade nao substitui estado do sensor nem origem do journal.
REF_TS='2026-01-15T12:21:00Z'
CURRENT_BOOT_EPOCH="$(date -d '2026-01-15T12:22:00Z' +%s)"
PREVIOUS_BOOT_START_EPOCH="$(date -d '2026-01-15T10:00:00Z' +%s)"
IPMI_CLOCK_OK=1
pair=$'0001 | 01/15/2026 | 12:10:00 UTC | Power Supply #0x01 | Power Supply AC lost | Asserted\n0002 | 01/15/2026 | 12:10:05 UTC | Power Supply #0x01 | Power Supply AC lost | Deasserted'
normal='2026-01-15T12:21:00Z host-exemplo systemd[1]: Reached target poweroff.target - System Power Off.'
near="$(filtra_ipmi_proximo "$REF_TS" "$pair")"
assert_eq "$(seleciona_falhas_ipmi "$near" "$REF_TS")" '' 'recuperacao antes da referencia cancela perda'
analyze "$normal" '' '' "$near"
assert_eq "$EXIT_CODE" 0 'recuperacao e desligamento ordenado preservam mecanismo'
assert_has "$result" 'Sequência de reinício/desligamento ordenado' 'energia nao sobrepoe sequencia normal'
assert_lacks "$result" 'Causa provável:' 'falha ja recuperada nao e causa provavel'
assert_has "$result" 'Deasserted' 'recuperacao continua visivel nos indicios'
analyze "$log" '' '' "$near" ''
assert_eq "$EXIT_CODE" 2 'falha recuperada e boot abrupto nao confirmam causa'
active="${pair%%$'\n'*}"
analyze "$normal" '' '' "$active"
assert_lacks "$result" 'Causa provável:' 'ate perda sem recuperacao nao sobrepoe sequencia normal'
analyze "$log" '' '' "$active" ''
assert_eq "$EXIT_CODE" 0 'perda sem recuperacao na referencia permanece candidata'
analyze "$request_log" '' '' "$active"
assert_has "$result" 'Solicitação de desligamento registrada' 'solicitacao explicita tem prioridade sobre SEL'
other_pair="$pair"
other_pair="${other_pair/12:10:05 UTC | Power Supply #0x01/12:10:05 UTC | Power Supply #0x02}"
assert_eq "$(seleciona_falhas_ipmi "$other_pair" "$REF_TS")" "$active" 'recuperacao de outro sensor nao cancela perda'
assert_eq "$(seleciona_falhas_ipmi "${pair/12:10:05/12:21:05}" "$REF_TS")" "$active" 'recuperacao apos ultimo registro nao descarta possivel interrupcao'
assert_eq "$(seleciona_falhas_ipmi "${pair/12:10:05/12:21:00}" "$REF_TS")" '' 'recuperacao exatamente na referencia cancela perda'
assert_eq "$(seleciona_falhas_ipmi "${pair#*$'\n'}"$'\n'"$active" "$REF_TS")" '' 'ordena datas antes de avaliar recuperacao'
new_loss='0003 | 01/15/2026 | 12:21:10 UTC | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(seleciona_falhas_ipmi "$pair"$'\n'"$new_loss" "$REF_TS")" "$new_loss" 'nova perda depois da recuperacao e considerada'
assert_eq "$(seleciona_falhas_ipmi "$pair" '')" '' 'sem referencia nao determina estado causal'

PREVIOUS_BOOT_START_EPOCH="$(date -d '2026-01-15T12:20:00Z' +%s)"
assert_eq "$(filtra_ipmi_proximo "$REF_TS" "$pair")" '' 'nao correlaciona evento anterior aos registros do boot'
boundary='0004 | 01/15/2026 | 12:20:00 UTC | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo "$REF_TS" "$boundary")" "$boundary" 'aceita limite inferior do boot'
assert_eq "$(filtra_ipmi_proximo "$REF_TS" "${boundary/12:20:00/12:22:00}")" '' 'evento no inicio do boot atual nao e do anterior'
PREVIOUS_BOOT_START_EPOCH=''
assert_eq "$(filtra_ipmi_proximo "$REF_TS" "$active")" '' 'sem limite inferior SEL fica historico'

quoted='2026-01-15T12:21:00Z host-exemplo app[42]: example: systemd[1]: Reached target poweroff.target - System Power Off.'
analyze "$quoted" '' '' '' ''
assert_eq "$EXIT_CODE" 2 'citacao por aplicativo nao confirma desligamento'
assert_eq "$(extrai_shutdown_ts "$quoted")" '' 'citacao nao contamina linha do tempo'
analyze "$normal" '' '' '' ''
assert_eq "$EXIT_CODE" 2 'tag systemd sem metadados confiaveis nao basta'
analyze "$quoted" '' '' '' "$quoted"
assert_eq "$EXIT_CODE" 2 'padrao exige emissor e inicio da mensagem mesmo na coleta confiavel'
quoted_logind='2026-01-15T12:21:00Z host-exemplo app[42]: systemd-logind[800]: System is powering down.'
analyze "$quoted_logind" '' '' '' "$quoted_logind"
assert_eq "$EXIT_CODE" 2 'citacao logind nao e solicitacao real'

# Limite de memoria, status do produtor e contagem de registros multiline.
status=0
captura_limitada 8 printf '123456789012345' > "$work/bounded" || status=$?
assert_eq "$status" 4 'limite de bytes sinaliza corte deliberado'
assert_eq "$(cat "$work/bounded")" 12345678 'saida limitada em bytes'
status=0
captura_limitada 3 printf '\n\n\n\n' > "$work/bounded" || status=$?
assert_eq "$status" 4 'newlines finais tambem contam no limite'
assert_eq "$(wc -c < "$work/bounded" | tr -d ' ')" 3 'preserva newlines ate o limite'
status=0
captura_limitada 3 bash -c 'printf parcial; exit 124' > "$work/bounded" || status=$?
assert_eq "$status" 124 'timeout nao e confundido com corte por tamanho'
assert_eq "$(cat "$work/bounded")" '' 'descarta dados de produtor com falha'
status=0
captura_limitada 3 bash -c 'printf parcial; exit 1' > "$work/bounded" || status=$?
assert_eq "$status" 1 'erro de leitura nao e ignorado por limite'
status=0
captura_limitada 3 printf 'abc' > "$work/bounded" || status=$?
assert_eq "$status" 0 'tamanho exatamente no limite e valido'
status=0
captura_limitada 8 yes 'linha sintetica' > "$work/bounded" || status=$?
assert_eq "$status" 4 'SIGPIPE por corte de produtor continuo e esperado'
assert_eq "$(wc -c < "$work/bounded" | tr -d ' ')" 8 'produtor continuo permanece limitado'

MODE=FAST
BOOT_END_EPOCH=1768479660.000000
BOOT_END_TS="$REF_TS"
PREVIOUS_BOOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# shellcheck disable=SC2317,SC2329
timeout() { shift 3; "$@"; }
# shellcheck disable=SC2317,SC2329
journalctl() { printf '%s\n' "$*" > "$work/args"; printf '%s\n' "$normal"; }
coleta_journal_sistema_boot_anterior > "$work/system" 2> "$work/warnings"
assert_has "$(cat "$work/args")" '_PID=1 _UID=0 + _SYSTEMD_UNIT=systemd-logind.service _COMM=systemd-logind _UID=0' 'filtro na fonte usa metadados confiaveis'
assert_lacks "$(cat "$work/args")" 'SYSLOG_IDENTIFIER=' 'tag fornecida pelo aplicativo nao e autoridade'
assert_has "$(cat "$work/args")" '--until @1768479660.000000' 'coleta confiavel preserva janela'
JOURNAL_MAX_BYTES=16
status=0
coleta_journal_boot_anterior > "$work/too-big" 2> "$work/warnings" || status=$?
assert_eq "$status" 3 'journal excedente e erro de coleta'
assert_eq "$(cat "$work/too-big")" '' 'journal cortado nao alimenta diagnostico'
assert_has "$(cat "$work/warnings")" 'bytes excedido' 'limite explica indisponibilidade'
JOURNAL_MAX_BYTES=8388608
FAST_LIMIT=2
# shellcheck disable=SC2317,SC2329
journalctl() { printf '%s\n' "$normal" '    continuation one' '    continuation two'; }
coleta_journal_boot_anterior > /dev/null 2> "$work/warnings"
assert_lacks "$(cat "$work/warnings")" 'registros atingido' 'continuacoes nao sao contadas como registros'
# shellcheck disable=SC2317,SC2329
journalctl() { printf '%s\n' "$normal" "$normal"; }
coleta_journal_boot_anterior > /dev/null 2> "$work/warnings"
assert_has "$(cat "$work/warnings")" '2 registros atingido' 'avisa limite real de registros'
FAST_LIMIT=1500
# shellcheck disable=SC2317,SC2329
journalctl() { :; }
status=0
coleta_journal_sistema_boot_anterior > /dev/null 2> "$work/warnings" || status=$?
assert_eq "$status" 0 'coleta confiavel vazia e normal'

# Inicio e fim independentes; erro opcional de limite inferior bloqueia so o SEL.
MODE=FULL
# shellcheck disable=SC2317,SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    elif [[ " $* " == *' --no-tail '* ]]; then
        printf '%s\n' '__REALTIME_TIMESTAMP=1768479600000000'
        printf '%05000d\n' 0
    else
        printf '%s\n' '__REALTIME_TIMESTAMP=1768479660000000'
    fi
}
prepara_journal
assert_eq "$PREVIOUS_BOOT_START_EPOCH" 1768479600 'primeiro registro lido mesmo com corte deliberado de metadados'
assert_eq "$BOOT_END_EPOCH" 1768479660.000000 'ultima referencia permanece independente'
# shellcheck disable=SC2317,SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    elif [[ " $* " == *' --no-tail '* ]]; then
        printf '%s\n' '__REALTIME_TIMESTAMP=1768479600000000'; return 124
    else
        printf '%s\n' '__REALTIME_TIMESTAMP=1768479660000000'
    fi
}
prepara_journal 2> "$work/warnings"
assert_eq "$PREVIOUS_BOOT_START_EPOCH" '' 'descarta inicio parcial em timeout'
assert_has "$(cat "$work/warnings")" 'SEL apenas como histórico' 'explica limite inferior indisponivel'
unset -f journalctl timeout

mkdir "$work/bad-logs"
printf 'not gzip\n' > "$work/bad-logs/syslog.gz"
coleta_logs_aux "$work/bad-logs" > "$work/history" 2> "$work/warnings"
assert_eq "$(cat "$work/history")" '' 'gzip corrompido nao gera evidencia parcial'
assert_has "$(cat "$work/warnings")" 'Coleta histórica incompleta' 'erro historico e visivel'
assert_lacks "$(cat "$work/warnings")" 'Nenhum evento relevante encontrado' 'falha nao e ausencia de eventos'
printf '%s\n' "$active" > "$work/bad-logs/syslog"
# shellcheck disable=SC2317,SC2329
timeout() { printf '%s\n' "$active"; return 124; }
coleta_logs_aux "$work/bad-logs" > "$work/history" 2> "$work/warnings"
assert_eq "$(cat "$work/history")" '' 'timeout historico descarta parcial'
assert_has "$(cat "$work/warnings")" 'código 124' 'timeout historico identificado'
unset -f timeout
mkdir "$work/large-logs"
{
    echo 'example kernel: Kernel panic - synthetic historical event'
    awk 'BEGIN {for (i=0; i<10000; i++) print "normal historical record with no causal pattern"}'
} | gzip > "$work/large-logs/syslog.gz"
AUX_MAX_BYTES=128
coleta_logs_aux "$work/large-logs" > "$work/history" 2> "$work/warnings"
assert_has "$(cat "$work/history")" 'Kernel panic - synthetic historical event' 'corte gzip preserva linha completa da amostra'
assert_has "$(cat "$work/warnings")" 'amostra descompactada limitada' 'corte deliberado e anunciado'
assert_lacks "$(cat "$work/warnings")" 'Coleta histórica incompleta' 'SIGPIPE esperado nao vira falha de leitura'
AUX_MAX_BYTES=2097152
mkdir "$work/empty-logs"
coleta_logs_aux "$work/empty-logs" > /dev/null 2> "$work/warnings"
assert_has "$(cat "$work/warnings")" 'Nenhuma amostra histórica pôde ser consultada' 'diretorio vazio nao implica consulta bem sucedida'

printf 'OK: %s verificações com dados sintéticos.\n' "$checks"
