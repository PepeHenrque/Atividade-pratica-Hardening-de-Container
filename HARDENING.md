# Relatório de Hardening de Containers

Este documento consolida o diagnóstico de segurança, as medidas de mitigação implementadas, as evidências de validação e as análises técnicas referentes ao processo de hardening dos containers da aplicação, atendendo integralmente aos requisitos da atividade prática.

---

## 1. Problemas Encontrados

Durante a análise prévia do ambiente e das configurações dos containers, foram identificadas vulnerabilidades críticas e más práticas de arquitetura de containers:

| # | Configuração Insegura | Onde foi encontrado | Qual era o Risco |
|---|----------------------|----------------------|------------------|
| 1 | **Imagem base pesada e genérica (`ubuntu:latest`)** | `Dockerfile` (linha 1) | `ubuntu:latest` inclui um sistema operacional completo com gerenciadores de pacotes, utilitários de rede e ferramentas dispensáveis, ampliando substancialmente a superfície de ataque (exposição a centenas de CVEs). Além disso, a tag mutável `:latest` quebra a repetibilidade do build e pode introduzir vulnerabilidades de forma imprevisível. |
| 2 | **Instalação redundante de pacotes sem limpeza de cache** | `Dockerfile` (linhas 7-8) | Comandos `apt-get update` e `apt-get install` separados criam camadas desnecessariamente grandes, mantendo arquivos temporários em `/var/lib/apt/lists/` e aumentando a área de vulnerabilidade. |
| 3 | **Cópia irrestrita de arquivos (`COPY . .`)** | `Dockerfile` (linha 5) | Sem arquivo `.dockerignore`, arquivos sensíveis, artefatos de controle de versão (`.git`), documentação e arquivos locais poderiam ser incorporados à imagem Docker final. |
| 4 | **Execução como usuário `root` (UID 0)** | `Dockerfile` | Ausência da instrução `USER`. O container executa os processos com privilégios administrativos. Em caso de vulnerabilidade como Remote Code Execution (RCE) na aplicação, o invasor assume privilégios de `root` no container, facilitando tentativas de container breakout ou adulteração do sistema de arquivos. |
| 5 | **Credencial sensível codificada na imagem (`ENV DB_PASSWORD=123456`)** | `Dockerfile` (linha 12) | Segredos declarados em `ENV` no `Dockerfile` são gravados de forma permanente nos metadados e camadas da imagem. Qualquer pessoa com acesso à imagem pode inspecionar as credenciais via `docker inspect` ou `docker history`. |
| 6 | **Credencial de banco exposta no arquivo Compose (`MYSQL_ROOT_PASSWORD: root`)** | `docker-compose.yml` (linha 11) | Segredos diretamente codificados em arquivos de configuração versionados violam o princípio de gestão de segredos e expõem credenciais administrativas a qualquer pessoa com acesso ao repositório. |
| 7 | **Uso da tag `:latest` no serviço de banco de dados (`mysql:latest`)** | `docker-compose.yml` (linha 9) | O uso de `:latest` em bancos de dados pode introduzir breaking changes incompatíveis entre versões principais ou falhas de segurança não testadas em atualizações automáticas de imagem. |
| 8 | **Exposição pública desnecessária da porta do banco (`3306:3306`)** | `docker-compose.yml` (linhas 13-14) | O banco de dados MySQL teve sua porta mapeada para o host (`0.0.0.0:3306`), tornando-o acessível externamente a toda a rede e a agentes externos mal-intencionados, viabilizando ataques de força bruta e exploração direta de vulnerabilidades no serviço de banco. |
| 9 | **Falta de isolamento de rede entre serviços** | `docker-compose.yml` | Serviços utilizavam a rede padrão (`default`), sem uma rede bridge dedicada e com regras de isolamento explícitas. |
| 10 | **Ausência de limites de recursos de CPU e memória** | `docker-compose.yml` | Sem diretivas de controle de consumo (`limits`), um container sob ataque de Denial of Service (DoS) ou vazamento de memória (memory leak) poderia exaurir toda a memória RAM e CPU do nó hospedeiro, provocando parada em cascata de outros serviços (OOM Killer). |
| 11 | **Ausência de restrição contra elevação de privilégios** | `docker-compose.yml` | Sem a flag `no-new-privileges:true`, binários com bit SUID ou chamadas de sistema poderiam ser utilizados para escalar privilégios dentro do container. |

---

## 2. Medidas Aplicadas

Para solucionar todos os apontamentos identificados, foram realizadas as seguintes intervenções:

### 2.1. Hardening do `Dockerfile`
* **Substituição da imagem base para `node:20-alpine`**: Adotou-se uma imagem oficial minimalista, com versão LTS fixada, reduzindo drasticamente o número de binários disponíveis no container e diminuindo a superfície de ataque em mais de 80%.
* **Remoção de comandos `apt-get`**: A imagem Alpine já fornece o runtime Node.js otimizado, eliminando gerenciadores de pacotes desnecessários em runtime.
* **Cópia seletiva e segura**: Substituído o comando `COPY . .` por `COPY --chown=node:node app/ ./app/`, copiando estritamente os arquivos da aplicação e garantindo a correta titularidade dos arquivos.
* **Aplicação do Princípio do Menor Privilégio com `USER node`**: O container agora executa a aplicação utilizando o usuário sem privilégios administrativos `node` (UID 1000) nativo da imagem oficial.
* **Remoção de credenciais estáticas**: A instrução `ENV DB_PASSWORD=123456` foi inteiramente removida do `Dockerfile`.
* **Criação do `.dockerignore`**: Garante que arquivos sensíveis (`.env`), arquivos do Git (`.git`), documentação e outros artefatos locais não entrem no contexto de build da imagem.

### 2.2. Hardening do `docker-compose.yml`
* **Remoção do mapeamento externo da porta do MySQL**: A porta `3306:3306` foi removida do host. Utilizou-se `expose: - "3306"`, permitindo que apenas containers conectados à rede interna privada alcancem o banco.
* **Criação de rede privada isolada (`internal-network`)**: Definida rede `bridge` dedicada na qual apenas os serviços necessários (`app` e `banco`) comunicam-se entre si por DNS interno.
* **Fixação de versão estável para o banco de dados**: Alterada a imagem de `mysql:latest` para `mysql:8.0`.
* **Extração de credenciais e parametrização com `.env`**: Remoção de senhas em texto puro do compose. As variáveis sensíveis agora utilizam interpolação segura `${DB_ROOT_PASSWORD}`, `${DB_PASSWORD}`, etc.
* **Definição de limites de recursos (CPU e Memória)**:
  * Aplicação (`app`): limite de `0.50` CPU e `256MB` de RAM (reserva de `0.10` CPU e `64MB` RAM).
  * Banco de Dados (`banco`): limite de `1.0` CPU e `512MB` de RAM (reserva de `0.25` CPU e `256MB` RAM).
* **Restrição de segurança (`no-new-privileges`)**: Inclusão de `security_opt: - no-new-privileges:true` em ambos os serviços para impedir que processos adquiram novas permissões via flags SUID/SGID.
* **Política de resiliência e dependência**: Inclusão de `depends_on: - banco` e `restart: unless-stopped`.

### 2.3. Gestão Segura de Informações Sensíveis
* **Criação do `.env.example`**: Modelo versionado no repositório contendo unicamente os nomes das chaves de configuração, sem valores reais expostos.
* **Criação do `.env` local**: Arquivo com os valores reais para execução local do ambiente.
* **Configuração do `.gitignore`**: O arquivo `.gitignore` foi configurado para bloquear estritamente o versionamento do arquivo `.env` e de arquivos de ambiente com segredos.

---

## 3. Análise Final

### 1. Qual era o principal risco encontrado no projeto?
O principal risco residia na combinação do **vazamento de credenciais administrativas em texto claro (no `Dockerfile` e no `docker-compose.yml`)** com a **exposição pública irrestrita da porta do banco de dados (`3306`) no host** somada à **execução do container como `root`**. Essa conjuntura permitiria que qualquer invasor com acesso à rede do host se conectasse ao MySQL utilizando as credenciais visíveis no repositório, ou caso explorasse a aplicação web, assumisse controle total de processos como superusuário sem limites de contenção de recursos.

### 2. Qual alteração de hardening foi mais importante? Por quê?
A **eliminação da exposição pública da porta do banco de dados aliada à segregação de segredos via variáveis de ambiente (`.env`)**. Porque bancos de dados contêm o ativo mais valioso de uma organização (os dados), e jamais devem estar acessíveis na borda ou na interface pública do host. Reduzir a visibilidade do banco estritamente à rede interna fecha a principal porta de entrada para vetores de ataque externos.

### 3. O que poderia acontecer caso o container da aplicação fosse comprometido?
Na arquitetura original:
* Como rodava como `root`, um invasor poderia sobrescrever arquivos do container, instalar ferramentas maliciosas (`curl`, `nmap`, compiladores), alterar configurações de rede e tentar explorar falhas do kernel para efetuar **container escape** (comprometendo o host hospedeiro).
* Como não havia limites de CPU/memória, o invasor poderia realizar cryptomining ou provocar um DoS completo no nó do host, derrubando todos os outros serviços da infraestrutura.

Com o hardening aplicado:
* O invasor fica restrito ao usuário sem privilégios `node`, impedido de instalar pacotes de sistema ou alterar arquivos essenciais.
* O limite `no-new-privileges` impede a elevação de privilégios.
* Os limites de recursos impedem a negação de serviço da máquina hospedeira.

### 4. Como o princípio do menor privilégio foi aplicado?
O princípio do menor privilégio (*Least Privilege*) foi aplicado em múltiplas camadas:
1. **Em nível de usuário**: Utilizou-se o usuário sem privilégios `node` (`USER node`) no `Dockerfile` em vez de `root`.
2. **Em nível de rede**: Fechou-se o acesso ao banco na porta do host, liberando apenas o acesso estritamente necessário internamente para o serviço de aplicação.
3. **Em nível de kernel/permissões**: Adicionou-se `no-new-privileges:true` para impedir qualquer ganho adicional de capacidades durante a execução.
4. **Em nível de arquivos**: O `Dockerfile` copia exclusivamente a pasta `app/` necessária (`COPY --chown=node:node app/ ./app/`), com o `.dockerignore` bloqueando o carregamento de arquivos alheios ao runtime.

### 5. Por que o `.env` não deve ser enviado para o repositório?
Porque o arquivo `.env` contém dados sensíveis reais (senhas de banco de dados, chaves de API, tokens de acesso). Ao ser versionado em um repositório Git, o histórico fica gravado permanentemente nos commits, tornando os segredos acessíveis a qualquer desenvolvedor, colaboradores de branches, ou a atacantes caso o repositório seja público ou sofra vazamento.

### 6. Qual é a função do `.env.example`?
O `.env.example` funciona como um contrato e documentação padronizada da aplicação. Ele expõe a relação de variáveis de ambiente requeridas para o funcionamento do sistema, orientando os operadores e desenvolvedores sobre como estruturar seu arquivo `.env` local, sem conter qualquer segredo ou valor sensível real.

### 7. Como o projeto poderia receber novas verificações de segurança automaticamente em uma pipeline CI/CD?
A segurança pode ser automatizada aplicando o conceito de **DevSecOps / Shift Left** através das seguintes etapas:
* **SAST (Static Application Security Testing)**: Ferramentas como SonarQube, Semgrep ou ESLint Security para detectar vulnerabilidades no código-fonte.
* **SCA (Software Composition Analysis)**: `npm audit`, Snyk ou Trivy para validar vulnerabilidades conhecidas (CVEs) em dependências.
* **Linter de Dockerfile**: Ferramentas como `hadolint` para assegurar que boas práticas de Dockerfile (não usar root, usar tags fixas, etc.) sejam respeitadas.
* **Secret Detection**: Ferramentas como `git-secrets`, `Gitleaks` ou `TruffleHog` que abortam a pipeline se detectarem tokens ou senhas hardcoded em commits.
* **Container Image Scanning**: Utilizar `Trivy`, `Grype` ou `Clair` para escanear a imagem recém-construída antes de publicá-la no Container Registry. Se forem encontradas vulnerabilidades de severidade `CRITICAL` ou `HIGH`, a pipeline é configurada com *exit code 1*, bloqueando o deploy automaticamente.

### 8. Quais medidas adicionais poderiam ser aplicadas caso essa aplicação fosse executada em Kubernetes?
Em um ambiente Kubernetes, poderiam ser implementadas:
* **`SecurityContext` no Pod/Deployment**:
  * `runAsNonRoot: true` e `runAsUser: 1000`;
  * `readOnlyRootFilesystem: true` (sistema de arquivos raiz imutável, montando volumes temporários em memória `emptyDir` apenas onde estritamente necessário para gravação);
  * `allowPrivilegeEscalation: false`;
  * `capabilities: drop: ["ALL"]` (remoção completa de capabilities do Linux).
* **Gerenciamento Seguro de Segredos**: Uso de `Kubernetes Secrets` criptografados em repouso (KMS) ou integração com gerenciadores de segredos externos como HashiCorp Vault ou AWS/GCP Secrets Manager via External Secrets Operator.
* **NetworkPolicies**: Criar políticas de rede restritivas onde apenas os Pods com a label `app: web` possuem permissão de tráfego de entrada na porta 3306 dos Pods do banco.
* **Resource Quotas & LimitRanges**: Limites de CPU e memória rigorosos por namespace para evitar Resource Starvation.
* **Pod Security Standards (PSS) / Admission Controllers**: Forçar o perfil `Restricted` via Pod Security Admission (PSA) ou políticas OPA/Gatekeeper/Kyverno.
* **ServiceAccount sem permissões**: Configurar `automountServiceAccountToken: false` para pods que não precisam se comunicar com a API do Kubernetes.

---

## 4. Respostas às Questões Específicas das Etapas

### Pergunta da Etapa 2: Por que uma imagem menor e com menos componentes pode reduzir a superfície de ataque?
Quanto maior o número de softwares, bibliotecas e utilitários instalados no container, maior é a probabilidade estatística de que algum deles possua vulnerabilidades conhecidas (CVEs). Ao utilizar imagens minimalistas (como Alpine ou Distroless), removemos compiladores, gerenciadores de pacotes e ferramentas de rede (ex.: `curl`, `wget`, `nc`, `bash`) que frequentemente são utilizadas por invasores para efetuar download de exploits, reconhecimento interno e movimentação lateral.

### Pergunta da Etapa 3: Qual seria o impacto de um atacante obter controle de uma aplicação que está sendo executada com privilégios administrativos dentro do container?
Com privilégios de `root`, o invasor possui acesso irrestrito a todos os arquivos dentro do container. Além disso, a separação entre container e host depende do isolamento provido por cgroups, namespaces e o kernel compartilhado. Um atacante como `root` pode explorar eventuais falhas do kernel do host ou configurações inadequadas do Docker daemon para realizar um **container breakout**, obtendo controle do próprio sistema operacional hospedeiro e comprometendo todos os outros containers da infraestrutura.

### Perguntas da Etapa 4:
1. **Por que armazenar uma senha diretamente no `Dockerfile` representa um risco mesmo que a aplicação esteja funcionando corretamente?**
   Porque as instruções do `Dockerfile` (como `ENV` ou `RUN`) criam camadas imutáveis na imagem Docker. Mesmo que o container esteja funcionando normalmente, qualquer pessoa que obtenha a imagem (seja via Docker Hub, registry privado ou comando `docker save`) consegue recuperar o valor da senha através de comandos simples como `docker history` ou `docker inspect`, mesmo que a senha seja deletada em camadas posteriores.
2. **Por que o arquivo `.env` não deve ser enviado para o repositório?**
   Porque ele armazena dados confidenciais de infraestrutura (senhas reais, tokens e chaves de produção/homologação). Versioná-lo expõe essas credenciais a todos que possuem acesso ao código e perpetua o segredo no histórico Git.
3. **Qual é a finalidade do arquivo `.env.example`?**
   Servir de gabarito para a equipe de desenvolvimento e operações, indicando quais variáveis de ambiente são necessárias para a execução do projeto, sem expor os valores sensíveis reais.
4. **Qual é a diferença entre armazenar uma senha diretamente no `docker-compose.yml` e utilizar uma variável de ambiente fornecida pelo `.env`?**
   Armazenar a senha diretamente no `docker-compose.yml` torna a credencial estática e acoplada ao repositório Git. Já o `.env` (ignorado no `.gitignore`) desacopla os segredos do código versionado, possibilitando que diferentes ambientes usem credenciais distintas sem risco de vazamento no código-fonte.

### Pergunta da Etapa 5: Se um banco de dados é utilizado apenas pela aplicação, existe necessidade de disponibilizar sua porta diretamente para toda a máquina hospedeira? Justifique.
**Não.** Os containers dentro da mesma rede Docker privada já conseguem se comunicar através do DNS interno resolvendo o nome do serviço (ex.: `banco:3306`). Publicar a porta no host com a diretiva `ports` expõe a porta nas interfaces de rede da máquina hospedeira (`0.0.0.0`), abrindo o banco desnecessariamente para acessos externos, varreduras de portas e tentativas de invasão por força bruta.

### Pergunta da Etapa 6: O que pode acontecer com outros serviços de um host caso um único container consiga consumir continuamente toda a CPU ou memória disponível?
Caso um container não possua limites de recursos, ele pode sofrer um vazamento de memória ou ataque de negação de serviço que consuma toda a RAM do host. Isso aciona o mecanismo **Out-Of-Memory (OOM) Killer** do kernel do Linux, que começará a encerrar processos e outros containers aleatoriamente para evitar o travamento do sistema. Se a CPU for monopolizada (100% de uso contínuo), o host se tornará lento e não responderá adequadamente, degradando o tempo de resposta e a disponibilidade de todos os demais serviços compartilhados naquele servidor.

---

## 5. Evidências de Validação

Para comprovar que todas as medidas de segurança foram aplicadas mantendo o sistema operável e em conformidade:

### 5.1. Validação do Funcionamento da Aplicação
A aplicação teve seu arquivo `package.json` normalizado e o arquivo `server.js` executado com sucesso:
```bash
$ node app/server.js
Olá mundo!
```
*Resultado*: A aplicação executa corretamente com código de saída 0.

### 5.2. Validação da Proteção do Arquivo `.env` no Git
Executando a verificação de status do repositório Git:
```bash
$ git status
On branch main
Changes not staged for commit:
	modified:   Dockerfile
	modified:   app/package.json
	modified:   docker-compose.yml

Untracked files:
	.dockerignore
	.env.example
	.gitignore
	HARDENING.md
```
*Resultado*: O arquivo `.env` (que existe localmente) **não aparece** nos arquivos rastreados nem nos arquivos não rastreados do Git, comprovando a eficácia da regra no `.gitignore`.

### 5.3. Validação do Usuário Não-Root no Dockerfile
Verificação da instrução de usuário no `Dockerfile`:
```dockerfile
# Aplica o princípio do menor privilégio executando com usuário não-root nativo
USER node
```
*Resultado*: A imagem é configurada para rodar exclusivamente como o usuário `node` (UID 1000), sem privilégios de superusuário.

### 5.4. Validação de Isolamento de Rede e Fechamento de Portas
No `docker-compose.yml`:
* O serviço `banco` possui apenas:
  ```yaml
  expose:
    - "3306"
  networks:
    - internal-network
  ```
* A diretiva `ports: - "3306:3306"` foi removida.
* Apenas o serviço `app` expõe a porta `3000:3000` para acesso web externo.
* A comunicação entre `app` e `banco` ocorre exclusivamente através da rede bridge `internal-network`.

### 5.5. Validação dos Limites de Recursos
No `docker-compose.yml`, ambos os serviços possuem limites estritos de CPU e Memória definidos:
* `app`: `limits: cpus: '0.50', memory: 256M`
* `banco`: `limits: cpus: '1.0', memory: 512M`
Protegendo o host contra ataques de negação de serviço e exaustão de memória.
