#!/bin/bash

# Pasta base onde todos os resultados serão armazenados
PASTA_BASE="Registros"
ARQUIVO_INDICE="$PASTA_BASE/.ids_index.txt"  # arquivo oculto para índice global

STOPWORDS=(
    a ante após até com contra de desde em entre para per por sem sob sobre trás
    e que
    da das do dos na nas no nos
    ao aos à às
    ele ela eles elas lhe lhes me te se nos vos
    o a os as
    um uma uns umas
    este esta estes estas esse essa esses essas aquele aquela aqueles aquelas
    isso isto aquilo
    deu dá fez faz
    muito pouco tudo nada sempre nunca também ainda já lá cá
    mas mais porém pois
)

# Função que remove stopwords de uma string
remover_stopwords() {
    local frase="$1"
    for sw in "${STOPWORDS[@]}"; do
        frase=$(echo "$frase" | sed -E "s/(^|[[:space:]])$sw($|[[:space:]])/\1\2/g" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    done
    echo "$frase"
}

# Função para verificar se o ID já existe no índice
verificar_duplicado() {
    local id="$1"
    if [ -f "$ARQUIVO_INDICE" ]; then
        if grep -q "^$id|" "$ARQUIVO_INDICE"; then
            return 0  # duplicado
        fi
    fi
    return 1  # não duplicado
}

# Função para adicionar ID ao índice
adicionar_ao_indice() {
    local id="$1"
    local pasta="$2"
    echo "$id|$pasta" >> "$ARQUIVO_INDICE"
}

# Cria a pasta base e o arquivo de índice (se não existir)
mkdir -p "$PASTA_BASE"
touch "$ARQUIVO_INDICE"

if [ $# -eq 0 ]; then
    echo "Uso: $0 \"termo1\" \"termo2\" ..."
    echo "Exemplo: $0 \"preconceito racial\" \"arte negra\""
    exit 1
fi

executar_busca() {
    local termos="$1"
    local slug=$(echo "$termos" | tr ' ' '_' | sed 's/[^a-zA-Z0-9_]/_/g')
    local pasta_base="${PASTA_BASE}/${slug}_resultados"
    mkdir -p "$pasta_base"

    echo "=========================================="
    echo "Buscando: $termos"
    echo "Pasta: $pasta_base"
    echo "=========================================="

    # Remove stopwords do termo de busca
    termos_limpos=$(remover_stopwords "$termos")
    [ -z "$termos_limpos" ] && termos_limpos="$termos"

    # Monta query para campo assunto (1=21)
    if [[ "$termos_limpos" =~ [[:space:]] ]]; then
        QUERY="find @and"
        for palavra in $termos_limpos; do
            QUERY="$QUERY @attr 1=21 $palavra"
        done
    else
        QUERY="find @attr 1=21 $termos_limpos"
    fi
    echo "Query gerada: $QUERY"

    HITS=$(
        (
            echo "base USP01"
            echo "$QUERY"
            echo "quit"
        ) | yaz-client dedalus.usp.br:9991 2>&1 | grep -i "Number of hits" | sed -E 's/.*Number of hits: ([0-9]+).*/\1/'
    )

    if ! [[ "$HITS" =~ ^[0-9]+$ ]]; then
        echo "Erro: não foi possível obter o número de hits para $termos."
        return 1
    fi
    echo "Total de registros encontrados: $HITS"

    # ------------------------------------------------------------------
    # 1. Baixar XML (todos de uma vez) e dividir em temporários
    # ------------------------------------------------------------------
    busca_tudo() {
        local FORMATO="$1"
        local OUT_RAW="$2"
        local CMDS
        CMDS=$(mktemp)
        {
            echo "base USP01"
            echo "format $FORMATO"
            echo "$QUERY"
            echo "show 1+$HITS"
            echo "quit"
        } > "$CMDS"
        yaz-client dedalus.usp.br:9991 < "$CMDS" > "$OUT_RAW" 2>&1
        rm "$CMDS"
    }

    RAW_XML=$(mktemp)
    busca_tudo "xml" "$RAW_XML"
    TEMP_XML_DIR=$(mktemp -d)
    awk 'BEGIN {RS="</dc-record>"; ORS=""} /<dc-record>/ {print $0 "</dc-record>"}' "$RAW_XML" > "$TEMP_XML_DIR/todos.xml"
    csplit --quiet --prefix="$TEMP_XML_DIR/temp_" --suffix-format="%05d.xml" "$TEMP_XML_DIR/todos.xml" '/<dc-record>/' '{*}'

    # Arrays para armazenar os XML temporários e seus índices
    declare -a XML_TEMPS
    index=0
    for xmlfile in "$TEMP_XML_DIR"/temp_*.xml; do
        [ -f "$xmlfile" ] || continue
        if grep -q "Connecting" "$xmlfile"; then
            rm "$xmlfile"
            continue
        fi
        XML_TEMPS+=("$xmlfile")
        ((index++))
    done

    # ------------------------------------------------------------------
    # 2. Baixar outros formatos (um por vez) e verificar duplicatas
    # ------------------------------------------------------------------
    baixa_registro() {
        local FORMATO="$1"
        local NUMERO="$2"
        local OUT_FILE="$3"
        local CMDS
        CMDS=$(mktemp)
        {
            echo "base USP01"
            echo "format $FORMATO"
            echo "$QUERY"
            echo "show $NUMERO"
            echo "quit"
        } > "$CMDS"
        yaz-client dedalus.usp.br:9991 < "$CMDS" > "$OUT_FILE" 2>&1
        rm "$CMDS"
    }

    # Cria as pastas de destino
    mkdir -p "$pasta_base/xml" "$pasta_base/marc" "$pasta_base/sutrs" "$pasta_base/opac"

    # Processa cada registro
    for ((i=0; i<HITS; i++)); do
        numero=$((i+1))
        xml_temp="${XML_TEMPS[$i]}"

        # Se o XML temporário não existe, pula
        [ -f "$xml_temp" ] || continue

        # Calcula o hash SHA-256 do arquivo XML (primeiros 16 caracteres)
        hash=$(sha256sum "$xml_temp" | cut -c1-16)

        # Verifica duplicata usando o hash
        if verificar_duplicado "$hash"; then
            echo "  Registro $numero (hash: $hash) já existe em outra pasta. Pulando."
            continue
        fi

        # Se for novo, salva todos os formatos usando o hash como nome
        # Salva XML
        cp "$xml_temp" "$pasta_base/xml/${hash}.xml"

        # Agora baixa MARC, SUTRS e OPAC para salvar
        for formato in USmarc SUTRS OPAC; do
            case "$formato" in
                (USmarc) pasta_fmt="marc" ;;
                (SUTRS)  pasta_fmt="sutrs" ;;
                (OPAC)   pasta_fmt="opac" ;;
            esac
            temp_out=$(mktemp)
            baixa_registro "$formato" "$numero" "$temp_out"
            cleaned_out=$(mktemp)
            sed -n '/\[USP01\]Record type:/,/nextResultSetPosition/ {
                /nextResultSetPosition/d
                p
            }' "$temp_out" > "$cleaned_out"
            if [ -s "$cleaned_out" ]; then
                cp "$cleaned_out" "$pasta_base/$pasta_fmt/${hash}.${pasta_fmt}"
            fi
            rm -f "$temp_out" "$cleaned_out"
        done

        # Adiciona ao índice
        adicionar_ao_indice "$hash" "$slug"
        echo "  Registro $numero (hash: $hash) adicionado."
    done

    # Limpa arquivos temporários
    rm -rf "$TEMP_XML_DIR" "$RAW_XML"

    echo "Concluído para '$termos'. Resultados em $pasta_base/"
    echo "=========================================="
}

# Executa para cada argumento
for arg in "$@"; do
    executar_busca "$arg"
done

echo "Todas as buscas foram concluídas. Resultados em '$PASTA_BASE/'"