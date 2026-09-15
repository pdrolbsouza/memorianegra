# Geração de arquivos de registro da Base USP

O código ainda está em versão inicial e sujeito a alterações, mas já é capaz de realizar buscas na base da USP e extrair as informações dos arquivos em `marc`, `xml`, `sutrs` e `opac`.

## Nomeação e identificação dos arquivos

Cada registro recebe um **identificador único baseado no hash SHA-256 do seu próprio conteúdo XML**. Especificamente, após o download e a limpeza do XML, é calculado o hash criptográfico desse conteúdo, e os **primeiros 16 caracteres hexadecimais** são usados como nome base do arquivo.

**Exemplo:** `a3f5c8d9e2b1a4c6.xml`


**Importante:** independentemente do formato (`xml`, `marc`, `sutrs`, `opac`), todos os arquivos referentes ao mesmo registro recebem o **mesmo hash** como nome, alterando apenas a extensão.

## Deduplicação automática

O script mantém um **índice global** no arquivo `Registros/.ids_index.txt`, que armazena todos os hashes já baixados. Antes de salvar um novo registro, o script verifica se o hash já existe nesse índice:

- **Se for novo** → baixa os formatos restantes (MARC, SUTRS, OPAC) e salva todos com o hash como nome.
- **Se já existir** → exibe a mensagem `"já existe em outra pasta. Pulando."` e ignora o registro.

Isso evita duplicatas mesmo quando o mesmo registro aparece em buscas com termos diferentes (ex: "Preconceito Racial" e "Racismo").

> Para reiniciar a coleção do zero, basta apagar a pasta `Registros/` ou o arquivo `Registros/.ids_index.txt`.

---

# Funcionamento

O script se resume a uma função principal (`executar_busca`). Para cada termo de busca fornecido, ele:

1. **Remove stopwords** do termo e **converte para maiúsculas** (exigido pelo servidor no campo de assunto).
2. **Monta a query** apropriada (ver seção "Critérios de personalização").
3. **Envia a busca** ao servidor e obtém o número total de hits (`$HITS`).
4. **Baixa todos os registros em XML** de uma só vez usando `show 1+$HITS`, dividindo o resultado em arquivos temporários (um por registro).
5. Para **cada registro**:
   - Calcula o **hash SHA-256** do XML (16 primeiros caracteres).
   - Consulta o **índice global** para verificar duplicata.
   - Se for novo, **baixa MARC, SUTRS e OPAC** individualmente (via `show $numero`) e salva todos os 4 formatos usando o hash como nome.

## ⚠️ IMPORTANTE: escopo da busca

O script foi configurado para buscar **apenas no campo de assunto** (`@attr 1=21`). Isso significa que os resultados podem ser mais restritos do que uma busca geral no `yaz-client`.

**Exemplo prático:**
- No cliente yaz: `find CANDOMBLÉ` → 594 resultados.
- No script: `./download.sh CANDOMBLÉ` → 460 resultados.

Isso ocorre porque apenas registros que possuem o termo como **descritor de assunto controlado** são retornados. Para capturar mais resultados (busca em todos os campos), substitua `@attr 1=21` por `@attr 1=7` na montagem da query.

---

# Utilização com uma lista de termos

O código acompanha um arquivo `termos.txt` contendo os descritores da biblioteca temática da USP. Para processar todos de uma vez:

```bash
while IFS= read -r termo; do
    ./download.sh "$termo"
    sleep 2   # pausa opcional para não sobrecarregar o servidor
done < termos.txt
```

## Nuances de execução

- **Termos compostos** (com espaços, ex: `"JOGO DE BÚZIOS"`) devem estar entre aspas no `termos.txt`. O script quebra a frase em palavras e monta a query com `@and` entre cada uma.
- **Stopwords**: palavras muito comuns (`da`, `de`, `do`, `e`, etc.) são removidas automaticamente para evitar falhas. Por exemplo, `"Extinção da África"` se torna `"Extinção África"` antes de virar query.
- **Acentos**: o script preserva acentos e caracteres especiais, enviando-os como estão para o servidor.

## Critérios de personalização da query

A variável `QUERY` é montada de duas formas:

- **Termo simples** (sem espaços): `find @attr 1=21 TERMO`
- **Termo composto** (com espaços): `find @and @attr 1=21 PALAVRA1 @attr 1=21 PALAVRA2 ...`

A query pode ser personalizada conforme a necessidade (mas isso cabe a fazer uma alteração dentro do código,não é algo disponível para o usuário do sistema):

| Atributo | Efeito |
| :--- | :--- |
| `@attr 1=21` | **Padrão do script.** Busca apenas no campo **Assunto** (vocabulário controlado). |
| `@attr 1=7` | Busca por palavras-chave em todos os campos (mais abrangente). |
| `@attr 4=1` | Busca por adjacência **exata** (a frase deve aparecer literalmente). |
| Sem atributo | Busca geral com comportamento padrão do servidor. |

---

# Estrutura de diretórios

Todos os resultados são salvos dentro da pasta `Registros/` (criada automaticamente). A estrutura final é:

```text
Registros/
├── .ids_index.txt                 ← índice global de hashes (arquivo oculto)
├── Preconceito_Racial_resultados/
│   ├── xml/                       ← arquivos .xml com hash como nome
│   ├── marc/                      ← arquivos .marc
│   ├── sutrs/                     ← arquivos .sutrs
│   ├── opac/                      ← arquivos .opac
│   └── saídas/                    ← CSVs gerados pelo extract_to_csv.py
├── Catimbó_resultados/
│   └── ...
├── ...
└── resultado_geral.csv            ← CSV consolidado com todos os registros
```

---

## Observações

- O script foi desenvolvido e testado em ambiente **Linux** com `yaz-client` instalado.
- Buscas grandes podem consumir tempo e recursos, por isso recomenda-se adicionar pausas entre execuções.
- Para depurar erros de busca, é útil testar manualmente no `yaz-client`.
- Termos com stopwords são ajustados automaticamente antes do envio ao servidor.

---

# Transformando os registros em `.CSV`

Além do download dos registros, tem o script Python `extract_to_csv.py`, que extrai informações estruturadas dos arquivos baixados e as organiza em uma planilha CSV. Ele percorre as pastas de resultados, lê os arquivos `.xml`, `.opac` e `.sutrs` de cada registro e gera um CSV com os campos mais relevantes.

## Como usar

O script pode ser executado de três formas:

```bash
# 1. Processar todas as pastas dentro de 'Registros/'
python3 extract_to_csv.py Registros

# 2. Processar apenas uma pasta específica
python3 extract_to_csv.py Registros/Preconceito_Racial_resultados

# 3. Filtrar por um identificador (hash) específico em todas as pastas
python3 extract_to_csv.py Registros a3f5c8d9e2b1a4c6
```
> Um pequeno adendo é que o código é bem sensível ao tamanho das letras. ex: P ≠ p. Então se for executar o código, padronize a forma como você está escrevendo

## Saída

Para cada pasta processada, o script cria uma subpasta `saídas/` e salva um CSV com nome:

- `resultados_<nome_da_pasta>.csv` — quando processa uma pasta inteira
- `saida_<hash>.csv` — quando filtra por um identificador

Além disso, ao final, é gerado um arquivo consolidado **`resultado_geral.csv`** dentro de `Registros/`, contendo **todos os registros de todas as pesquisas**.

## Campos extraídos

O script escaneia diferentes formatos e coleta os seguintes dados:

| Coluna | Fonte | Descrição |
| :--- | :--- | :--- |
| **identifier** | Nome do arquivo | Hash SHA-256 (16 caracteres) do registro |
| **titulo** | XML (`<title>`) | Título completo do trabalho |
| **autor** | XML (`<contributor>`) | Autor principal (sem datas ou ORCIDs) |
| **co_autor** | XML (`<contributor>`) | Coautores (se houver mais de um contribuidor) |
| **orientador** | XML (`<contributor>`) | Orientador (último contribuidor, quando há mais de um) |
| **data** | XML (`<date>`) | Ano de publicação |
| **paginas** | XML (`<format>`) | Extensão ou número de páginas |
| **local_publicacao** | XML (`<coverage>`) | Local de publicação (ex: BRASIL) |
| **subjects** | XML (`<subject>`) | Assuntos/descritores, separados por `\|` |
| **modelo_trabalho** | SUTRS (`Tipo de material:`) | Tipo traduzido (ex: "Tese", "Periódico") |
| **descricao** | XML (`<description>`) | Resumo (fallback para SUTRS se ausente) |
| **local_defesa** | SUTRS (`Imprenta:`) | Cidade de defesa/publicação |

## Tratamento de informações

- **Limpeza do autor**: remove datas, ORCIDs e sufixos desnecessários.
- **Mapeamento de tipo**: códigos como `T`, `D`, `P` são traduzidos para descrições legíveis (`T` → Tese, `P` → Periódico / Parte de livro).
- **Decodificação de caracteres**: sequências como `S\XC3\XA3o Paulo` são convertidas para `São Paulo`.
- **Normalização Unicode**: todos os textos passam por normalização NFC, garantindo consistência nos acentos.
- **Fallback de descrição**: se o XML não tiver `<description>`, o script busca `Nota de resumo:` no SUTRS.

## Exemplo de saída

| identifier | titulo | autor | co_autor | orientador | data | paginas | local_publicacao | subjects | modelo_trabalho | descricao | local_defesa |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| a3f5c8d9e2b1a4c6 | Oriente-se marcas da assimilação asiática no Brasil... | Nakamura, Aline Watanabe |  | Ambra, Pedro | 2023 | 142 p | BRASIL | PRECONCEITO RACIAL\|ORIENTALISMO\|... | Tese | A presente pesquisa... | São Paulo |