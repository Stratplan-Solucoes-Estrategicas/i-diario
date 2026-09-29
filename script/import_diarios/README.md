# Importação de diários (Frequência + Conteúdo) a partir de planilhas exportadas

Importa os arquivos `.xlsx` de "Diário" (formato: abas *Detalhes do diário*,
*Frequências*, *Conteúdos*, *Resultados*, *Observações*) para dentro do i-Diário,
criando/atualizando `DailyFrequency` + `DailyFrequencyStudent` e `ContentRecord`.

## Passo 1 — extrair as planilhas para JSON

Roda no seu Mac (fora do Docker), precisa de `openpyxl` (`pip install openpyxl`):

```bash
python3 script/import_diarios/extract_diarios.py "/caminho/da/pasta/com/os/xlsx" /tmp/diarios.json
```

## Passo 2 — copiar o JSON para dentro do container

```bash
docker cp /tmp/diarios.json idiario-puma:/tmp/diarios.json
```

## Passo 3 — rodar em modo DRY-RUN (não grava nada)

```bash
docker compose exec puma bundle exec rails runner script/import_diarios/import_diarios.rb /tmp/diarios.json <entity> 
```

`<entity>` é o nome da Entity (ex.: `iconha`). O dry-run mostra, pra cada arquivo:

- **OK**: escola/turma/professor/componente curricular resolvidos, com o tipo de
  frequência detectado (Geral ou Por disciplina) e quantas frequências/conteúdos
  seriam criados.
- **[PULADO]**: não conseguiu resolver escola, turma, professor ou componente —
  mostra as opções que EXISTEM no sistema pra você comparar e decidir (renomear a
  turma na planilha, cadastrar o vínculo professor×turma×componente que falta, etc.).
- **[ATENÇÃO]**: aluno casado só pela data de nascimento (nome na planilha bate só
  parcialmente com o nome no sistema) — confira se é a pessoa certa antes de commitar.
- **Alunos NÃO encontrados**: nem nome nem data de nascimento bateram com ninguém
  matriculado na turma — geralmente typo forte ou gêmeos com o mesmo nome
  quase-igual (aí o script não arrisca adivinhar).

## Passo 4 — gravar de verdade (ou gerar SQL pra outro time rodar)

Só depois de revisar o dry-run e resolver as pendências que fizerem sentido, duas opções:

**a) Gravar direto neste banco:**

```bash
docker compose exec puma bundle exec rails runner script/import_diarios/import_diarios.rb /tmp/diarios.json <entity> --commit
```

**b) Gerar um `.sql` pra mandar pro time de desenvolvimento rodar em outro ambiente**
(ex.: produção), sem gravar nada aqui:

```bash
docker compose exec puma bundle exec rails runner script/import_diarios/import_diarios.rb /tmp/diarios.json <entity> --sql=/tmp/import_diarios.sql
```

Roda a MESMA lógica de resolução (dentro de uma transação que é sempre desfeita no
final — nada é gravado neste banco), capturando os INSERTs/UPDATEs reais que o Rails
executaria. O arquivo gerado:

- Roda com `psql <conexão> -v ON_ERROR_STOP=1 -f arquivo.sql` — **não** copiar/colar
  num client SQL qualquer, porque usa `\gset` (comando do `psql`).
- Ids de linhas novas em `contents`, `content_records` e `daily_frequencies` **não**
  ficam gravados como valor fixo (o id que o Postgres deu neste banco de teste não
  necessariamente existe/está livre no banco de destino) — são capturados em tempo
  real via `RETURNING "id" \gset vN_` e reusados como `:vN_id` nos INSERTs
  seguintes que dependem deles (ex.: `content_records_contents`,
  `discipline_content_records`). Ids de linhas que já existiam antes desta importação
  (turma, professor, componente, aluno, ou um `content` com texto repetido)
  continuam fixos, porque são referência estável entre os dois bancos.
- Não inclui a trilha de auditoria (tabela `audits`) — não é essencial pro import e
  complicaria o encadeamento de ids; o histórico de auditoria só fica completo se
  rodar via `--commit` direto pelo Rails.
- Testado rodando o `.sql` gerado sozinho via `psql` (sem Rails) contra o banco
  `iconha` local, sem erros.

É **idempotente**: pode rodar de novo (dry-run, commit ou sql) que não duplica
frequência nem conteúdo já importados — cada dia/turma/disciplina é
`find_or_initialize_by`, e conteúdo já existente pra aquele
professor/turma/disciplina/data é pulado.

## O que o script NÃO faz (por segurança)

- Não cria turma, professor, componente curricular ou vínculo entre eles — só usa o
  que já existe. Se a planilha referenciar algo que não existe no sistema, ela fica
  **pulada** e reportada, não é "resolvida na marra".
- Não adivinha entre dois alunos com nome quase-igual E mesma data de nascimento
  (ex.: gêmeos) — fica pulado pra você decidir manualmente.
- Não escreve nada em modo dry-run (padrão) — só com `--commit` explícito.

## Casos observados no lote "pré e AEE" (Iconha, EMPEF Isabelo Fontana)

- **Pré I / Pré II — Corpo, Gestos e Movimentos** e **Traços, Sons, Cores e Formas**:
  resolvem automaticamente.
- **Pré I / Pré II — Campos de Experiências (Principal)**: a planilha junta em UM
  diário os 3 "campos de experiência" (EU/O OUTRO/NOS, ESCUTA/FALA/PENSAMENTO/
  IMAGINACAO, ESPAÇOS/TEMPOS/QUANTIDADES/RELAÇÕES/TRANSFORMAÇÕES), que no sistema
  são 3 componentes curriculares SEPARADOS vinculados à mesma professora. Precisa
  decidir com a coordenação pedagógica: importar como conteúdo por área de
  conhecimento (`knowledge_area_content_record`) ou dividir manualmente entre os 3
  componentes antes de importar.
- **AEE Vespertino Pré I/Pré II/4º/5º**: essas turmas específicas não existem no
  sistema — só existe uma turma combinada "AEE VESPERTINO I" (matutino tem versões
  por série: 3º, 6º). Precisa decidir: criar as turmas por série no i-Diário antes
  de importar, ou consolidar tudo na "AEE VESPERTINO I" existente.
- Julia e Paula Calenzani Zandomenighe (mesma data de nascimento — gêmeas) foram
  casadas automaticamente por data de nascimento + primeiro nome.
- 3 alunos não foram encontrados matriculados na turma "AEE VESPERTINO I" (Hiago
  Alochio Mozer, Agatha Amorin Mozer, Brenner Rodrigues Carias) — provavelmente
  porque as planilhas de origem eram de turmas AEE por série/período que foram
  consolidadas numa turma só no sistema, e esses alunos específicos não têm
  matrícula na turma consolidada. Decisão da coordenação pedagógica: matricular
  esses 3 alunos na turma antes de reimportar, ou aceitar que a frequência/conteúdo
  deles fique de fora.
