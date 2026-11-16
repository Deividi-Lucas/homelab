#!/usr/bin/env bash
# Prepara um Raspberry Pi 4 (Raspberry Pi OS Lite 64-bit) com k3s + Argo CD.
# Rode na pasta do repositório homelab, no Pi:
#   sudo bash bootstrap/instalar-k3s.sh
# Na primeira vez ele liga o controle de memória e pede para reiniciar; depois rode de novo.
# Para restaurar a chave do Sealed Secrets (recuperação), passe o arquivo:
#   sudo CHAVE_SEALED=/caminho/sealed-secrets-chave.yaml bash bootstrap/instalar-k3s.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Rode com sudo: sudo bash bootstrap/instalar-k3s.sh"; exit 1; }

K3S_VERSAO="v1.37.2+k3s1"
ARGOCD_CHART_VERSAO="10.18.0"
KUBESEAL_VERSAO="0.41.2"
KUBESEAL_SHA256="8a73c0b252f6c0e8752a7a749da51f55a6e99dc5603e3bd29ed3c00ff9e82db2"
ORIGEM="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Cuidados com o cartão SD"
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=50M\n' > /etc/systemd/journald.conf.d/homelab.conf
systemctl restart systemd-journald
if command -v dphys-swapfile >/dev/null 2>&1; then
  dphys-swapfile swapoff || true
  dphys-swapfile uninstall || true
  systemctl disable --now dphys-swapfile || true
fi
if dpkg -s rpi-swap >/dev/null 2>&1; then
  echo "    rpi-swap já cuida do zram neste sistema"
else
  apt-get update
  apt-get install -y zram-tools
  printf 'ALGO=lz4\nPERCENT=25\n' > /etc/default/zramswap
  systemctl enable --now zramswap || true
fi
sed -i.bak -E '/[[:space:]]\/[[:space:]]+ext4[[:space:]]/ { /noatime/! s/(ext4[[:space:]]+)([^[:space:]]+)/\1\2,noatime/ }' /etc/fstab

echo "==> Controle de memória (cgroups)"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
if ! grep -q 'cgroup_memory=1' "$CMDLINE"; then
  cp "$CMDLINE" "$CMDLINE.bak"
  sed -i '1 s/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"
  echo
  echo "Ativei o controle de memória. Reinicie o Pi (sudo reboot) e rode este script de novo."
  exit 0
fi
if ! grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  echo "O controle de memória ainda não está ativo. Reinicie o Pi (sudo reboot) e rode de novo."
  exit 1
fi

echo "==> Pasta do pendrive de backup"
[ -d /mnt/backup ] || mkdir -m 700 /mnt/backup

echo "==> k3s $K3S_VERSAO"
install -d /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'CONFIG'
write-kubeconfig-mode: "0600"
disable:
  - traefik
  - servicelb
kubelet-arg:
  - container-log-max-size=5Mi
  - container-log-max-files=2
  - image-gc-high-threshold=80
  - image-gc-low-threshold=60
CONFIG
if ! command -v k3s >/dev/null 2>&1 || ! k3s --version | grep -qF "$K3S_VERSAO"; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSAO" sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 5; done

echo "==> kubeseal $KUBESEAL_VERSAO (para criar segredos aqui no Pi)"
if ! command -v kubeseal >/dev/null 2>&1 || ! kubeseal --version | grep -qF "$KUBESEAL_VERSAO"; then
  TMP="$(mktemp -d)"
  ARQ="kubeseal-${KUBESEAL_VERSAO}-linux-arm64.tar.gz"
  curl -fsSL -o "$TMP/$ARQ" "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSAO}/${ARQ}"
  echo "$KUBESEAL_SHA256  $TMP/$ARQ" | sha256sum -c -
  tar -xzf "$TMP/$ARQ" -C "$TMP" kubeseal
  install -m 755 "$TMP/kubeseal" /usr/local/bin/kubeseal
  rm -rf "$TMP"
fi

if [ -n "${CHAVE_SEALED:-}" ]; then
  echo "==> Restaurando a chave do Sealed Secrets"
  kubectl apply -f "$CHAVE_SEALED"
fi

echo "==> Argo CD (chart $ARGOCD_CHART_VERSAO, pelo controlador de Helm do k3s)"
VALORES="$(sed 's/^/    /' "$ORIGEM/bootstrap/argocd-values.yaml")"
cat > /var/lib/rancher/k3s/server/manifests/argocd.yaml <<MANIFESTO
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  repo: https://argoproj.github.io/argo-helm
  chart: argo-cd
  version: "$ARGOCD_CHART_VERSAO"
  targetNamespace: argocd
  valuesContent: |-
$VALORES
MANIFESTO
until kubectl get crd applications.argoproj.io >/dev/null 2>&1; do sleep 5; done
until kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; do sleep 5; done
kubectl -n argocd rollout status deploy/argocd-server --timeout=900s

echo "==> App de apps (daqui em diante tudo vem do Git)"
kubectl apply -f "$ORIGEM/apps/root.yaml"

echo
echo "Pronto. Acompanhe com: sudo kubectl get applications -n argocd"
if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  echo "Senha inicial do Argo CD (usuário admin):"
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  echo
fi
