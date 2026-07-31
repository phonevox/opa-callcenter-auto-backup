# opa-callcenter-auto-backup

![Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![Docker](https://img.shields.io/badge/docker-required-2496ED?logo=docker&logoColor=white)
![Redis](https://img.shields.io/badge/redis-backup-DC382D?logo=redis&logoColor=white)
![MongoDB](https://img.shields.io/badge/mongodb-backup-47A248?logo=mongodb&logoColor=white)
![Discord](https://img.shields.io/badge/notifications-discord-5865F2?logo=discord&logoColor=white)

Solução customizada de backup para o OPA Callcenter.

## bin/phonevox-redis-mongo-backup.sh

Gera backup do Redis e MongoDB rodando em containers Docker, e envia via `pbackup` pro endpoint UOE.

```bash
./bin/phonevox-redis-mongo-backup.sh
```

Rodar manualmente sem argumentos executa o backup. O destino do upload é o drive customizado UOE (`pbackup -t <url> --token <token>`), URL e token vêm do `bin/uoe.env`.

```bash
./bin/phonevox-redis-mongo-backup.sh --help   # mostra ajuda
./bin/phonevox-redis-mongo-backup.sh --logs   # acompanha o log em tempo real (tail -f)
```

### O que o script faz

- Antes de gerar qualquer backup, valida se `docker` e `pbackup` estão instalados, se `bin/uoe.env` está preenchido, se os containers `redis`/`mongodb` estão rodando e respondem a um `PING` (Redis) / `ping` (Mongo).
- **Redis**: `docker exec redis redis-cli SAVE`, copia o `dump.rdb` gerado (via bind mount em `/var/lib/redis/data/dump.rdb`) com nome timestampado.
- **MongoDB**: `docker exec mongodb mongodump --archive --gzip`, autenticando com `MONGO_USER`/`MONGO_PASS`. Gera um arquivo único `.gz` por execução, depois quebra ele em partes de `$MONGO_SPLIT_SIZE` (300M) com `split -b` antes de subir - a UOE rejeita upload único grande demais (HTTP 400 "request file too large"). Usamos `split` (corte de bytes, sem recompressão) em vez do `-a`/`-C` nativo do `pbackup`, porque aquele autocompacta com `tar`+`zip` single-thread e é lento demais pra dumps grandes (trava 1 core por horas).
- Faz upload de todas as partes via `pbackup --files -t "$UOE_URL" --token "$UOE_TOKEN"` (drive UOE) e limpa o staging local (`bin/tmp/`, criado e removido a cada execução) após o envio.
- Notifica um webhook do Discord no início, no fim (sucesso) e em qualquer erro (via `trap ... EXIT`, cobre até falhas na validação).

### Requisitos

- `docker` instalado, containers `redis` e `mongodb` rodando (o Mongo precisa ter o `mongo` shell disponível dentro do container, usado no health check).
- `pbackup` e `rclone` instalados.
- Arquivos de credenciais do Mongo e do UOE preenchidos (veja abaixo).
- `curl` instalado (usado para notificar o Discord).

### Setup: credenciais (Mongo, Discord, UOE)

Cada integração tem um arquivo `.env.example` versionado (documentado, com placeholders) e um `.env` real (versionado vazio). Após dar `git pull`:

```bash
cd bin
cp mongo.env.example   mongo.env
cp discord.env.example discord.env
cp uoe.env.example     uoe.env
chmod 600 mongo.env discord.env uoe.env
```

Edite os três `.env` com os valores reais:

| Arquivo | Variáveis | Obrigatório? |
|---|---|---|
| `mongo.env` | `MONGO_USER`, `MONGO_PASS` | sim |
| `uoe.env` | `UOE_URL`, `UOE_TOKEN` | sim (destino do upload) |
| `discord.env` | `DISCORD_WEBHOOK_URL` | não - se vazio, só pula as notificações |

`bin/mongo.env`, `bin/discord.env` e `bin/uoe.env` já estão versionados (vazios), então o `.gitignore` sozinho não impede que as credenciais preenchidas sejam commitadas por engano. Para isso, rode uma vez por máquina:

```bash
git update-index --skip-worktree bin/mongo.env bin/discord.env bin/uoe.env
```

Isso faz o git ignorar futuras alterações de conteúdo desses arquivos específicos, mantendo os templates vazios intactos no histórico (os `.env.example` continuam normais, sem skip-worktree).

### Restore

O backup do Redis sobe como um único arquivo (`.rdb`), sem segredo pra restaurar. O do MongoDB sobe **em partes** (`mongobackup-<timestamp>.archive.gz.part.000`, `.part.001`, ...) - precisa juntar antes de restaurar:

```bash
# 1. baixe todas as partes de /mongodb pro mesmo diretório local

# 2. reconstrua o .gz original (a ordem importa - os sufixos numéricos garantem isso com o wildcard)
cat mongobackup-<timestamp>.archive.gz.part.* > mongobackup-<timestamp>.archive.gz

# 3. restaure direto (mongorestore lê --gzip nativamente, não precisa descompactar à parte)
mongorestore --archive=mongobackup-<timestamp>.archive.gz --gzip \
    -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase call-center
```

Importante: **não** dá pra usar `unzip` aqui - as partes são um corte bruto de bytes (`split -b`), não um ZIP multi-volume. Só reconstrói com `cat`, na ordem certa.

### Cron

```
0 3 * * * /caminho/repo/bin/phonevox-redis-mongo-backup.sh >> /var/log/pbackup.log 2>&1
```
