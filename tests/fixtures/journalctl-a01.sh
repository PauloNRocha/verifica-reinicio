#!/usr/bin/env bash
# Journal sintetico: respeita -n e distingue dados/metadados e os tres filtros.
# As populacoes de cada consulta sao independentes para isolar os estados.
set -euo pipefail
kind=geral
limit=1500
metadata=0
while (( $# )); do
    case "$1" in
        -n) limit="$2"; shift ;;
        -k) kind=kernel ;;
        _PID=1) kind=sistema ;;
        --output-fields=__CURSOR) metadata=1 ;;
    esac
    shift
done
scenario="${A01_SCENARIO:?}"
total=1
positive=''
hidden=0
case "$scenario" in
    orcamento-*)
        if [[ "$kind" == sistema ]]; then
            if (( metadata )); then
                if [[ "${A01_IGNORE_TERM:-0}" == 1 ]]; then
                    trap '' TERM
                    exec sleep "${A01_META_DELAY:?}"
                fi
                sleep "${A01_META_DELAY:?}"
                (( ${A01_META_EXIT:-0} == 0 )) || exit "$A01_META_EXIT"
            else
                sleep "${A01_DATA_DELAY:?}"
                positive=ordenado
            fi
        fi
        ;;
    completo-ordenado) [[ "$kind" != sistema ]] || positive=ordenado ;;
    completo-panic) [[ "$kind" != kernel ]] || positive=panic ;;
    completo-request) [[ "$kind" != sistema ]] || positive=request ;;
    limite-*-*|exato-*-*|positivo-panic-*|positivo-ordenado-*|positivo-request-*|ipmi-*-*)
        if [[ "$scenario" == *"-$kind-"* ]]; then total=$((limit + 1)); fi
        [[ "$scenario" != exato-* || "$total" -eq 1 ]] || total="$limit"
        case "$scenario" in
            positivo-panic-*) [[ "$kind" != kernel ]] || positive=panic ;;
            positivo-ordenado-*) [[ "$kind" != sistema ]] || positive=ordenado ;;
            positivo-request-*) [[ "$kind" != sistema ]] || positive=request ;;
        esac
        ;;
    shutdown-oculto-*)
        if [[ "$kind" != kernel ]]; then total=$((limit + 1)); hidden=1; fi
        ;;
    sem-message-*)
        if [[ "$kind" == sistema ]]; then total=$((limit + 1)); hidden=2; fi
        ;;
    blob-*) [[ "$kind" != sistema ]] || positive=blob ;;
    multiline-*) [[ "$kind" != sistema ]] || positive=multiline ;;
    positivo-com-geral-truncado-*)
        [[ "$kind" != geral ]] || total=$((limit + 1))
        [[ "$kind" != sistema ]] || positive=ordenado
        ;;
    positivo-com-kernel-truncado-*)
        [[ "$kind" != kernel ]] || total=$((limit + 1))
        [[ "$kind" != sistema ]] || positive=ordenado
        ;;
    falha-kernel-com-ordenado)
        [[ "$kind" != kernel ]] || exit 124
        [[ "$kind" != sistema ]] || positive=ordenado
        ;;
    timeout-real-geral)
        [[ "$kind" != geral ]] || sleep 10
        ;;
    probe-falha-kernel-com-panic)
        if [[ "$kind" == kernel ]]; then (( ! metadata )) || exit 1; positive=panic; fi
        ;;
    probe-timeout-sistema-com-ordenado)
        if [[ "$kind" == sistema ]]; then (( ! metadata )) || exit 124; positive=ordenado; fi
        ;;
    falha-*|timeout-*|bytes-*|probe-falha-*|probe-timeout-*|probe-bytes-*)
        if [[ "$scenario" == *"-$kind" ]]; then
            case "$scenario" in
                falha-*) echo '2026-01-15T12:21:00Z host-exemplo kernel: Kernel panic - saida parcial'; exit 1 ;;
                timeout-*) echo '2026-01-15T12:21:00Z host-exemplo kernel: Kernel panic - saida parcial'; exit 124 ;;
                bytes-*)
                    if (( ! metadata )); then
                        echo '2026-01-15T12:21:00Z host-exemplo kernel: Kernel panic - parte inicial integra'
                        awk 'BEGIN {printf "    %09000000d\n", 0}'
                        exit 0
                    fi
                    ;;
                probe-falha-*) (( ! metadata )) || exit 1 ;;
                probe-timeout-*) (( ! metadata )) || exit 124 ;;
                probe-bytes-*)
                    if (( metadata )); then awk 'BEGIN {printf "__CURSOR=s=ficticio;i=%09000000d\n",0}'; exit 0; fi
                    ;;
            esac
        fi
        ;;
esac
returned="$total"
(( returned <= limit )) || returned="$limit"
awk -v count="$returned" -v total="$total" -v meta="$metadata" -v kind="$kind" -v pos="$positive" -v hidden="$hidden" '
BEGIN {
    prefix="2026-01-15T12:21:00.000000+00:00 host-exemplo "
    for (i=total-count+1; i<=total; i++) {
        if (meta) {print "__CURSOR=s=ficticio;i=" i; print ""; continue}
        if (hidden == 2 && i != total) continue
        msg="app[42]: evento sintetico " i
        if (kind == "kernel") msg="kernel: evento sintetico " i
        if (kind == "sistema") msg="systemd[1]: evento sintetico " i
        if (hidden == 1 && i == 1) msg="systemd[1]: Reached target poweroff.target - System Power Off."
        if (i == total) {
            if (pos == "panic") msg="kernel: Kernel panic - not syncing"
            if (pos == "ordenado") msg="systemd[1]: Reached target poweroff.target - System Power Off."
            if (pos == "request") msg="systemd-logind[80]: System is powering down."
            if (pos == "blob") msg="systemd[1]: [64B blob data]"
        }
        print prefix msg
        if (pos == "multiline") for (j=0;j<1600;j++) print "    continuacao sintetica " j
    }
}'
