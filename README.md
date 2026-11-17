# homelab

Configuração do meu Raspberry Pi 4: um cluster **k3s** de um nó, gerido por **GitOps com Argo CD**.
Tudo o que roda no Pi está descrito aqui; o Argo CD aplica sozinho o que estiver na branch `main`.

| Pasta | O que tem |
|---|---|
| `bootstrap/` | Script que prepara o Pi (uma vez) e os valores do Argo CD |
| `platform/` | Componentes da plataforma: Sealed Secrets, operador do Tailscale, acesso ao Argo CD |
| `apps/` | `root.yaml` (o "app de apps") e uma pasta por serviço |

Serviços: **NotePi** (`apps/notepi/`) — anotações; o código fica em https://github.com/Deividi-Lucas/NotePi.

## Versões fixadas

| Componente | Versão |
|---|---|
| k3s | v1.37.2+k3s1 |
| Argo CD (chart `argo-cd`) | 10.18.0 (Argo CD v3.6.1) |
| Sealed Secrets (chart) | 2.22.0 (controlador v0.41.2) |
| kubeseal | 0.41.2 |
| Operador do Tailscale (chart) | 1.104.7 |
| rclone (imagem) | 1.76.0 |

Para atualizar: mude a versão no arquivo correspondente, faça um PR (a CI valida) e junte na `main`.

## Instalação

### 1. O que você precisa
- Raspberry Pi 4 (4 ou 8 GB), cartão SD de alta durabilidade (32 GB+), fonte oficial de 5,1 V / 3 A.
- Pendrive para o backup.
- Conta no Tailscale com **MagicDNS** e **HTTPS Certificates** ligados (painel → DNS).
- Os repositórios `homelab` e `NotePi` no GitHub.

### 2. Gravar o cartão
No **Raspberry Pi Imager**: Raspberry Pi OS Lite (64-bit). Nas opções: nome `homelab`, usuário e senha, SSH ligado,
fuso `America/Sao_Paulo`, Wi-Fi só se não for usar cabo.

### 3. Regras de acesso do Tailscale (antes de instalar)
No painel do Tailscale → **Access controls**, acrescente (mantendo o que já existe):

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:k8s": ["tag:k8s-operator"]
  },
  "grants": [
    {"src": ["autogroup:admin"], "dst": ["tag:k8s"], "ip": ["443"]}
  ]
}
```

Assim só você (administrador da tailnet) acessa os serviços do cluster.

Depois, em **Settings → OAuth clients**, crie um cliente para o operador com os escopos **Devices Core**,
**Auth Keys** e **Services** (escrita) e a tag `tag:k8s-operator`. Guarde o *Client ID* e o *Client secret*
(usados no passo 6).

### 4. Pendrive de backup
No Pi, formate o pendrive (ext4 é o mais simples), descubra o UUID com `lsblk -f` e acrescente ao `/etc/fstab`:

```
UUID=<uuid>  /mnt/backup  ext4  defaults,noatime,nofail  0  2
```

```bash
sudo mkdir -p /mnt/backup
sudo systemctl daemon-reload && sudo mount -a
sudo chown 10001:10001 /mnt/backup          # 10001 = usuário dos containers do NotePi
sudo touch /mnt/backup/.notepi-pendrive     # marcador: diz ao backup que o pendrive está lá
sudo chown 10001:10001 /mnt/backup/.notepi-pendrive
```

### 5. Instalar o k3s e o Argo CD
```bash
sudo apt-get install -y git
git clone https://github.com/Deividi-Lucas/homelab.git ~/homelab
cd ~/homelab
sudo bash bootstrap/instalar-k3s.sh      # na 1ª vez pede para reiniciar
sudo reboot
cd ~/homelab && sudo bash bootstrap/instalar-k3s.sh
```

No fim ele mostra a **senha inicial do Argo CD** (usuário `admin`). Acompanhe:

```bash
sudo kubectl get applications -n argocd
```

O operador do Tailscale só fica saudável depois do passo 6 (ele precisa do segredo OAuth).

### 6. Segredos (Sealed Secrets)
Os segredos vão para o Git **criptografados**; só este cluster consegue abrir. Os comandos abaixo rodam no Pi
(o bootstrap já instalou o `kubeseal`). Use `read -s` para a senha não ficar no histórico do terminal.

Antes, confira que o Sealed Secrets está rodando (`sudo kubectl get pods -n kube-system | grep sealed`) e salve o
**certificado público** dele. Ele não é segredo: só tranca, não abre. Assim o `kubeseal` não precisa falar com o
cluster (e não esbarra na configuração do `kubectl`):
```bash
sudo kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > ~/selo.pem
head -1 ~/selo.pem      # -----BEGIN CERTIFICATE-----
```

**OAuth do operador do Tailscale:**
```bash
read -rp "Client ID: " ID; read -rsp "Client secret: " SEGREDO; echo
sudo kubectl create secret generic operator-oauth -n tailscale \
  --from-literal=client_id="$ID" --from-literal=client_secret="$SEGREDO" \
  --dry-run=client -o yaml \
  | kubeseal --cert ~/selo.pem --format yaml > platform/tailscale-oauth.yaml
unset ID SEGREDO
grep -A3 encryptedData platform/tailscale-oauth.yaml    # valores longos começando com "Ag"
```

**Backup na nuvem do NotePi** (rclone com escopo `drive.file` + criptografia `crypt`, como no README do NotePi):
crie o `rclone.conf` no PC com os remotes `gdrive` e `cofre`, copie para o Pi e:
```bash
sudo kubectl create secret generic notepi-rclone -n notepi \
  --from-file=rclone.conf=./rclone.conf --dry-run=client -o yaml \
  | kubeseal --cert ~/selo.pem --format yaml > apps/notepi/sealedsecret-rclone.yaml
shred -u ./rclone.conf
```

Depois de gerar os dois arquivos, devolva as anotações do Argo CD que o `kubeseal` não copia:
- em `platform/tailscale-oauth.yaml`, em `metadata.annotations`:
  `argocd.argoproj.io/sync-wave: "2"` e `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`;
- em `apps/notepi/sealedsecret-rclone.yaml`: `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`.

Para não precisar de login do GitHub no Pi, traga os arquivos para o PC (são criptografados, pode copiar à vontade)
e faça commit e push de lá:
```powershell
scp <usuario>@<ip-do-pi>:~/homelab/platform/tailscale-oauth.yaml C:\caminho\do\homelab\platform\
```
O Argo CD aplica sozinho em até 3 minutos.

**Guarde a chave do Sealed Secrets** (sem ela, um cartão novo não abre os segredos do Git):
```bash
sudo kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-chave.yaml
```
Copie esse arquivo para o seu gerenciador de senhas e apague do Pi (`shred -u sealed-secrets-chave.yaml`).

### 7. Nome do seu tailnet no NotePi
Em `apps/notepi/configmap.yaml`, troque `SEU-TAILNET` pelo nome do seu tailnet (painel → DNS, algo como
`tail1234.ts.net`). Commit e push.

### 8. Conferir
```bash
sudo kubectl get pods -A                 # tudo Running
sudo kubectl top pods -A                 # plataforma em torno de 1,1 GB no total
```
- Abra `https://argocd.<tailnet>.ts.net`, entre com `admin` e **troque a senha** (User Info → Update password);
  depois: `sudo kubectl -n argocd delete secret argocd-initial-admin-secret`.
- Abra `https://notepi.<tailnet>.ts.net` e crie uma nota.
- Teste o backup agora:
  ```bash
  sudo kubectl -n notepi create job --from=cronjob/notepi-backup teste-backup
  sudo kubectl -n notepi logs job/teste-backup --all-containers
  ls -l /mnt/backup
  ```
- Faça um push no NotePi e veja a versão nova chegar sozinha (Actions → homelab → Argo CD).

## Se o cartão SD morrer
1. Grave um cartão novo (passo 2) e monte o pendrive (passo 4; o marcador já está nele).
2. Traga `sealed-secrets-chave.yaml` do gerenciador de senhas para o Pi e rode:
   ```bash
   git clone https://github.com/Deividi-Lucas/homelab.git ~/homelab && cd ~/homelab
   sudo bash bootstrap/instalar-k3s.sh && sudo reboot
   cd ~/homelab && sudo CHAVE_SEALED=~/sealed-secrets-chave.yaml bash bootstrap/instalar-k3s.sh
   shred -u ~/sealed-secrets-chave.yaml
   ```
3. O Argo CD recria tudo. Restaure os dados do NotePi:
   ```bash
   sudo kubectl -n notepi scale deploy/notepi --replicas=0
   POD=$(sudo kubectl -n notepi run restaurar --image=busybox:1.37 --restart=Never --overrides='{"spec":{"securityContext":{"runAsUser":10001,"runAsGroup":10001},"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"notepi-dados"}},{"name":"b","hostPath":{"path":"/mnt/backup","type":"Directory"}}],"containers":[{"name":"restaurar","image":"busybox:1.37","command":["sh","-c","cp /b/notas-AAAA-MM-DD.db /d/notas.db && rm -f /d/notas.db-wal /d/notas.db-shm"],"volumeMounts":[{"name":"d","mountPath":"/d"},{"name":"b","mountPath":"/b","readOnly":true}]}]}}' -o name)
   sudo kubectl -n notepi wait --for=jsonpath='{.status.phase}'=Succeeded "$POD" --timeout=120s
   sudo kubectl -n notepi delete "$POD"
   sudo kubectl -n notepi scale deploy/notepi --replicas=1
   ```
   (troque `AAAA-MM-DD` pela data do backup; se o pendrive também se perdeu, baixe antes de `cofre:backup` com o
   rclone no PC e copie para `/mnt/backup`.)

## Comandos úteis
- Estado do Argo CD: `sudo kubectl get applications -n argocd`
- Logs do NotePi: `sudo kubectl -n notepi logs deploy/notepi`
- Último backup: `sudo kubectl -n notepi get jobs`
- Forçar sincronização: no painel do Argo CD, botão **Sync**.
