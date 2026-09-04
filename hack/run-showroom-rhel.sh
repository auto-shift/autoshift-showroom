#!/usr/bin/env bash
#
# run-showroom-rhel.sh — stand up this Showroom lab on a single RHEL 9/10 host.
#
# Reproduces the RHDP showroom pod with rootless Podman + host nginx:
#
#   browser ──> nginx :${SHOWROOM_PORT}
#                 ├─ /            -> nookbag   127.0.0.1:8088  (split-pane UI + tabs)
#                 ├─ /wetty       -> wetty     127.0.0.1:3000  (ssh back into this host)
#                 └─ /stream/     -> zt-runner 127.0.0.1:8081  (SSE solve/validate)
#
# The zt-runner shells out to `ansible-playbook` with a copy of its own environ,
# and this lab's playbooks call plain `oc`. So a kubeconfig shared between your
# login shell and the runner container is all the cluster auth that is needed:
# run `oc login` once in the Terminal tab and the Solve/Validate buttons work.
#
# Run as an ordinary user (NOT root). sudo is used only for dnf/firewalld/nginx.
#
# Usage:
#   ./hack/run-showroom-rhel.sh install    # packages, oc, ssh key, selinux, firewall
#   ./hack/run-showroom-rhel.sh build      # antora build -> ./www
#   ./hack/run-showroom-rhel.sh up         # start pod + write nginx config
#   ./hack/run-showroom-rhel.sh all        # install + build + up
#   ./hack/run-showroom-rhel.sh down       # stop and remove the pod
#   ./hack/run-showroom-rhel.sh status     # container + endpoint health
#   ./hack/run-showroom-rhel.sh logs [c]   # follow logs (default: runner)
#
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
# Override any of these in the environment before invoking.

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHOWROOM_PORT="${SHOWROOM_PORT:-8080}"     # port nginx listens on
POD_NAME="${POD_NAME:-showroom}"

# Lab environment values. These land in two places: the Antora attributes that
# the guide renders, and the user_data extravars handed to every playbook.
GUID="${GUID:-local}"
CONSOLE_URL="${CONSOLE_URL:-}"             # https://console-openshift-console.apps.<cluster>
API_URL="${API_URL:-}"                     # https://api.<cluster>:6443
INGRESS_DOMAIN="${INGRESS_DOMAIN:-}"       # apps.<cluster>
SSH_USER="${SSH_USER:-$(id -un)}"
BASTION_HOST="${BASTION_HOST:-$(hostname -f)}"

# Modules 6 and 7 validate against a clone of the autoshiftv2 repo, which they
# find via $AUTOSHIFT_REPO (falling back to $HOME/autoshiftv2). The student
# clones it in the Terminal tab, so the host path is bind-mounted into the
# runner and AUTOSHIFT_REPO is pointed at the mount.
AUTOSHIFT_REPO_HOST="${AUTOSHIFT_REPO_HOST:-$HOME/autoshiftv2}"

# Images — the same ones AgnosticD uses for a real RHDP deployment.
IMG_NOOKBAG="${IMG_NOOKBAG:-quay.io/rhpds/nookbag:v0.4.0}"
IMG_WETTY="${IMG_WETTY:-quay.io/rhpds/wetty:v3.0}"
IMG_RUNNER="${IMG_RUNNER:-quay.io/rhpds/zt-runner:v2.5.0}"
IMG_ANTORA="${IMG_ANTORA:-docker.io/antora/antora:3.1.15}"

STATE_DIR="${STATE_DIR:-$HOME/.local/share/showroom}"
KEY_FILE="$STATE_DIR/wetty_ed25519"
UI_CONFIG="$STATE_DIR/ui-config.yml"
USER_DATA="$STATE_DIR/user_data.yml"
NGINX_CONF="/etc/nginx/conf.d/showroom.conf"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ─── install ─────────────────────────────────────────────────────────────────

cmd_install() {
  [[ $EUID -ne 0 ]] || die "run as a regular user, not root — sudo is used where needed"

  say "Installing packages"
  sudo dnf install -y podman git nginx openssh-server policycoreutils-python-utils

  say "Enabling sshd (wetty ssh's back into this host)"
  sudo systemctl enable --now sshd

  if ! command -v oc >/dev/null 2>&1; then
    say "Installing the oc client"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/oc.tar.gz" \
      https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
    sudo tar -xzf "$tmp/oc.tar.gz" -C /usr/local/bin oc kubectl
    rm -rf "$tmp"
  fi
  oc version --client

  say "Creating an ssh key for the wetty container"
  mkdir -p "$STATE_DIR" "$HOME/.ssh" "$HOME/.kube"
  chmod 700 "$HOME/.ssh"
  if [[ ! -f "$KEY_FILE" ]]; then
    ssh-keygen -t ed25519 -N '' -C 'showroom-wetty' -f "$KEY_FILE"
  fi
  touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  grep -qF "$(cat "$KEY_FILE.pub")" "$HOME/.ssh/authorized_keys" \
    || cat "$KEY_FILE.pub" >> "$HOME/.ssh/authorized_keys"

  say "Ensuring subuid/subgid ranges exist for rootless user namespaces"
  grep -q "^$(id -un):" /etc/subuid || sudo usermod --add-subuids 100000-165535 "$(id -un)"
  grep -q "^$(id -un):" /etc/subgid || sudo usermod --add-subgids 100000-165535 "$(id -un)"
  podman system migrate

  say "SELinux: letting nginx proxy to the pod"
  sudo setsebool -P httpd_can_network_connect 1

  if systemctl is-active --quiet firewalld; then
    say "Opening ${SHOWROOM_PORT}/tcp"
    sudo firewall-cmd --add-port="${SHOWROOM_PORT}/tcp" --permanent
    sudo firewall-cmd --reload
  fi

  say "Enabling linger so the pod survives logout"
  sudo loginctl enable-linger "$(id -un)" || true
}

# ─── build ───────────────────────────────────────────────────────────────────

# Rewrite the placeholder attributes in content/antora.yml. On RHDP these are
# replaced at runtime from the Showroom user_data; here we bake them in.
patch_attributes() {
  local f="$REPO_DIR/content/antora.yml"
  local -A map=(
    [guid]="$GUID"
    [bastion_public_hostname]="$BASTION_HOST"
    [bastion_ssh_user_name]="$SSH_USER"
    [ssh_user]="$SSH_USER"
    [openshift_console_url]="$CONSOLE_URL"
    [openshift_api_url]="$API_URL"
    [openshift_cluster_ingress_domain]="$INGRESS_DOMAIN"
  )
  for k in "${!map[@]}"; do
    [[ -n "${map[$k]}" ]] || continue
    sed -i -E "s|^([[:space:]]*${k}:).*|\1 ${map[$k]}|" "$f"
  done
  say "Patched content/antora.yml (git checkout content/antora.yml to revert)"
}

cmd_build() {
  # site.yml declares the content source as `url: .`, and Antora requires a
  # local content source to be a git repository — it reads the worktree of the
  # checked-out branch, so uncommitted edits are picked up, but a plain
  # directory fails with "Local content source must be a git repository".
  [[ -d "$REPO_DIR/.git" ]] \
    || die "$REPO_DIR is not a git repository. Antora needs one for 'url: .' in site.yml — clone the repo rather than copying the files, or run 'git init && git add -A && git commit -m snapshot' in it."

  patch_attributes
  say "Building the Antora site into ./www"
  # site.yml uses only local extensions, so the stock antora image is enough.
  podman run --rm \
    --userns=keep-id --user "$(id -u)" \
    -e HOME=/antora -e ANTORA_CACHE_DIR=/antora/.cache \
    -v "$REPO_DIR:/antora:z" \
    "$IMG_ANTORA" --fetch site.yml
  [[ -f "$REPO_DIR/www/modules/index.html" ]] \
    || die "build produced no www/modules/index.html"
  say "Built $(find "$REPO_DIR/www/modules" -name '*.html' | wc -l) pages"
}

# ─── config generation ───────────────────────────────────────────────────────

write_ui_config() {
  mkdir -p "$STATE_DIR"
  # nookbag builds tab URLs as <protocol>//<hostname>[:port]<path>, so the port
  # must be the port nginx listens on — the committed ui-config.yml hardcodes
  # 443 for RHDP.
  #
  # Deliberately NO antora: block. Its schema makes `modules` required whenever
  # the key is present, and an antora: block without it fails validation and
  # nookbag renders nothing. Omitted, `type: showroom` gives exactly the right
  # defaults: dir=www, name=modules, no version segment -> www/modules/*.html.
  cat > "$UI_CONFIG" <<EOF
---
type: showroom
default_width: 30
persist_url_state: true

view_switcher:
  enabled: true
  default_mode: split

tabs:
  - name: Terminal
    path: /wetty
    port: ${SHOWROOM_PORT}
EOF
  [[ -n "$CONSOLE_URL" ]] && cat >> "$UI_CONFIG" <<EOF
  - name: OpenShift Console
    url: '${CONSOLE_URL}'
EOF
  [[ -n "$INGRESS_DOMAIN" ]] && cat >> "$UI_CONFIG" <<EOF
  - name: Argo CD
    url: 'https://openshift-gitops-server-openshift-gitops.${INGRESS_DOMAIN}'
EOF
  say "Wrote $UI_CONFIG"
}

write_user_data() {
  # zt-runner reads /user_data/user_data.yml first and passes every scalar key
  # through to ansible-playbook as an extravar. k8s_kubeconfig is pulled out and
  # passed as its own -e, which is the path the runner sees, not the host path.
  cat > "$USER_DATA" <<EOF
---
guid: ${GUID}
user: ${SSH_USER}
bastion_public_hostname: ${BASTION_HOST}
bastion_ssh_user_name: ${SSH_USER}
bastion_ssh_port: 22
k8s_kubeconfig: /app/.kube/config
openshift_console_url: ${CONSOLE_URL}
openshift_api_url: ${API_URL}
openshift_cluster_ingress_domain: ${INGRESS_DOMAIN}
EOF
  say "Wrote $USER_DATA"
}

write_nginx_conf() {
  sudo tee "$NGINX_CONF" >/dev/null <<EOF
# Generated by run-showroom-rhel.sh

server {
    listen ${SHOWROOM_PORT};
    server_name _;

    # Live playbook output. SSE dies behind any buffering or read timeout.
    location /stream/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        proxy_read_timeout 3600s;
        proxy_connect_timeout 3600s;
    }

    # Terminal tab — wetty is a websocket app. ^~ and the long read timeout
    # match charts/zerotouch/templates/proxy/configmap-nginx-config.yaml in
    # rhpds/showroom-deployer, so an idle terminal is not dropped mid-lab.
    location ^~ /wetty {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_read_timeout 43200s;
    }

    # nookbag: the split-pane shell, ui-config.yml, and the built www/ site.
    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
  sudo nginx -t
  # Some images (RHDP sandboxes among them) start nginx by hand at provisioning
  # time rather than through systemd. That stray master holds :80 and makes
  # `systemctl start nginx` fail with EADDRINUSE. Hand ownership to systemd.
  if pgrep -x nginx >/dev/null && ! systemctl is-active --quiet nginx; then
    say "Stopping a non-systemd nginx so systemd can take over"
    sudo pkill -x nginx || true
    for _ in 1 2 3 4 5; do pgrep -x nginx >/dev/null || break; sleep 1; done
  fi
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx
  say "Wrote $NGINX_CONF"
}

# ─── up / down ───────────────────────────────────────────────────────────────

cmd_up() {
  [[ -f "$REPO_DIR/www/modules/index.html" ]] || die "no www/ yet — run '$0 build' first"
  [[ -f "$KEY_FILE" ]] || die "no ssh key — run '$0 install' first"

  write_ui_config
  write_user_data

  say "Pulling images"
  for i in "$IMG_NOOKBAG" "$IMG_WETTY" "$IMG_RUNNER"; do podman pull -q "$i"; done

  cmd_down >/dev/null 2>&1 || true

  say "Creating pod $POD_NAME"
  # keep-id:uid=1001 is load-bearing. All three images run as uid 1001, which
  # rootless Podman would otherwise map to a subuid — leaving the 0600 ssh key
  # and ~/.kube/config unreadable inside the containers. This maps container
  # uid 1001 to your host uid so the bind mounts just work. Needs Podman >= 4.3.
  podman pod create --name "$POD_NAME" \
    --userns=keep-id:uid=1001,gid=0 \
    -p "127.0.0.1:8088:8080" \
    -p "127.0.0.1:3000:3000" \
    -p "127.0.0.1:8081:8081" >/dev/null

  say "Starting nookbag"
  podman run -d --pod "$POD_NAME" --name showroom-nookbag \
    -v "$REPO_DIR/www:/var/www/html/www:ro,z" \
    -v "$UI_CONFIG:/var/www/html/ui-config.yml:ro,z" \
    "$IMG_NOOKBAG" >/dev/null

  say "Starting wetty"
  podman run -d --pod "$POD_NAME" --name showroom-wetty \
    -v "$KEY_FILE:/key:ro,z" \
    "$IMG_WETTY" \
      --host 0.0.0.0 --port 3000 --base /wetty/ \
      --ssh-host host.containers.internal \
      --ssh-port 22 \
      --ssh-user "$SSH_USER" \
      --ssh-auth publickey \
      --ssh-key /key \
      --allow-iframe \
      --title "Showroom Terminal" >/dev/null

  say "Starting zt-runner"
  # ~/.kube is mounted as a DIRECTORY on purpose: `oc login` replaces the config
  # file, so a file bind mount would go stale on the first login.
  mkdir -p "$AUTOSHIFT_REPO_HOST"
  podman run -d --pod "$POD_NAME" --name showroom-runner \
    -e PORT=8081 \
    -e KUBECONFIG=/app/.kube/config \
    -e BASE_DIR=/app \
    -e AUTOSHIFT_REPO=/app/autoshiftv2 \
    -v "$AUTOSHIFT_REPO_HOST:/app/autoshiftv2:z" \
    -v "$REPO_DIR/runtime-automation:/app/runtime-automation:ro,z" \
    -v "$USER_DATA:/user_data/user_data.yml:ro,z" \
    -v "$HOME/.kube:/app/.kube:z" \
    "$IMG_RUNNER" >/dev/null

  write_nginx_conf

  echo
  say "Showroom is up:  http://$(hostname -f):${SHOWROOM_PORT}/"
  cat <<EOF

Next: open the Terminal tab and authenticate to the cluster —

    oc login --server=${API_URL:-https://api.<cluster>:6443} -u <user> -p <password>
    oc whoami

That writes ~/.kube/config on this host, which the runner container reads at
/app/.kube/config. The Solve and Validate buttons use the same credentials.

Modules 6 and 7 also validate against a clone of autoshiftv2. Clone it in the
Terminal tab to ${AUTOSHIFT_REPO_HOST} and the runner sees it immediately:

    git clone https://github.com/auto-shift/autoshiftv2 ${AUTOSHIFT_REPO_HOST}

EOF
}

cmd_down() {
  say "Removing pod $POD_NAME"
  podman pod rm -f "$POD_NAME"
}

cmd_status() {
  podman ps --pod --filter "pod=$POD_NAME" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  echo
  printf 'runner /health : '; curl -fsS "http://127.0.0.1:8081/health" || echo UNREACHABLE; echo
  printf 'runner /config : '; curl -fsS "http://127.0.0.1:8081/config" || echo UNREACHABLE; echo
  printf 'nookbag        : '; curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8088/ui-config.yml" || true
  printf 'front door     : '; curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${SHOWROOM_PORT}/" || true
  echo
  printf 'kubeconfig     : '
  if podman exec showroom-runner test -r /app/.kube/config 2>/dev/null; then
    echo 'readable inside the runner'
    printf 'cluster        : '; oc whoami --show-server 2>/dev/null || echo 'not logged in'
  else
    echo 'MISSING — run oc login in the Terminal tab'
  fi
}

cmd_logs() { podman logs -f "showroom-${1:-runner}"; }

case "${1:-all}" in
  install) cmd_install ;;
  build)   cmd_build ;;
  up)      cmd_up ;;
  all)     cmd_install; cmd_build; cmd_up ;;
  down)    cmd_down ;;
  status)  cmd_status ;;
  logs)    cmd_logs "${2:-runner}" ;;
  *)       die "usage: $0 {install|build|up|all|down|status|logs [nookbag|wetty|runner]}" ;;
esac
