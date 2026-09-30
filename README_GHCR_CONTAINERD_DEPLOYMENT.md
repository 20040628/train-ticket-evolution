# Train Ticket 演化版：发布 GHCR 镜像并部署到 containerd Kubernetes

最后核对日期：2026-09-30

本指南用于完成以下目标：

- 使用已经独立并推送完成的 GitHub 仓库 `20040628/train-ticket-evolution`。
- 使用 GitHub Actions 编译项目并构建 46 个业务镜像。
- 将镜像发布到 GitHub Container Registry（GHCR）。
- 根据使用范围选择 GHCR Public 匿名拉取，或保持 Private 并通过 Kubernetes Secret 拉取。
- 在远程、多节点、运行时为 containerd 的 Kubernetes 集群中，将演化版部署到 `train-evolution` namespace。
- 保留演化前版本在 `train` namespace 中继续运行。

## 1. 先理解源码、镜像仓库和 containerd 的关系

完整链路如下：

```text
GitHub 源码仓库
  └─ GitHub Actions：Maven 编译 + Docker/OCI 镜像构建
       └─ GHCR Public/Private 镜像：ghcr.io/20040628/<服务名>:<标签>
            └─ Kubernetes kubelet
                 └─ 通过 CRI 请求 containerd 拉取并运行镜像
```

需要注意：

1. GitHub 代码仓库存放源码、Dockerfile 和部署文件，不要上传镜像 tar 包。
2. GHCR 才是 Kubernetes 拉取镜像的地址。
3. Kubernetes 节点使用 containerd 不影响通过 GitHub Actions/Docker 构建镜像。Docker 和 containerd 都能使用标准 OCI/Docker 镜像。
4. `make deploy` 不会编译本地源码；它只生成部署清单并让 Kubernetes 拉取指定镜像。
5. 公开 GHCR 镜像不需要 `imagePullSecret`。私有镜像才需要认证。

本项目演化版镜像将使用如下地址：

```text
ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930
ghcr.io/20040628/ts-order-service:log-evolution-v1-20260930
ghcr.io/20040628/ts-gateway-service:log-evolution-v1-20260930
...
```

不要使用 `latest`。当前部署脚本会拒绝演化版使用 `latest`，而且唯一标签可以避免 containerd 使用旧缓存。

## 2. 准备条件

### 2.1 GitHub 侧

- GitHub 仓库：`https://github.com/20040628/train-ticket-evolution`
- 账号对该仓库具有写权限。
- 仓库允许运行 GitHub Actions。
- Actions 的工作流权限允许写入 GitHub Packages：仓库 `Settings` → `Actions` → `General` → `Workflow permissions`。工作流本身也会声明 `packages: write`。

不要把 GitHub Token、Kubernetes kubeconfig、数据库密码或其他密钥提交到仓库。

### 2.2 Kubernetes 侧

部署控制机需要：

- `kubectl`
- Helm 3
- GNU Make
- Bash（Linux、WSL 或 Git Bash）
- 能访问正确集群的 kubeconfig

集群需要：

- 所有工作节点能够访问 `ghcr.io:443`。
- 有足够 CPU、内存和磁盘运行约 46 个业务服务及 MySQL、Nacos、RabbitMQ、SkyWalking、Elasticsearch。
- 有可用的默认 StorageClass，否则 MySQL PVC 可能保持 `Pending`。
- 节点架构与镜像一致。本指南中的 GitHub-hosted runner 默认构建 `linux/amd64` 镜像，因此节点应为 `amd64`。如果节点包含 `arm64`，需要额外构建多架构镜像。

部署前检查：

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,RUNTIME:.status.nodeInfo.containerRuntimeVersion
kubectl get storageclass
kubectl get all -n train
helm version
```

确认节点运行时输出类似：

```text
containerd://1.x.x
```

## 3. 确认独立仓库与远程地址

当前目录已经是独立的 `train-ticket-evolution` Git 仓库，源码也已经推送到 GitHub。后续不需要压缩成 ZIP，也不要执行 `docker save` 后把 tar 文件提交进源码仓库。

先确认当前目录和远程地址：

```bash
cd train-ticket-evolution
git rev-parse --show-toplevel
git remote -v
git status --short
```

当前项目的远程仓库应为：

```text
https://github.com/20040628/train-ticket-evolution.git
```

如果 `git remote -v` 仍显示旧地址 `train-ticket-myself.git`，GitHub 可能暂时通过仓库重命名跳转处理访问，但建议显式更新本地地址：

```bash
git remote set-url origin https://github.com/20040628/train-ticket-evolution.git
git remote -v
git fetch origin
```

不要提交以下内容：

- `.idea/`
- 各服务的 `target/`
- `*.tar` 镜像文件
- kubeconfig、Token、密码、私钥
- 仅供本地 AI 对话交接使用的文件，除非确认需要公开

后续修改直接在当前仓库根目录提交。示例：

```bash
git add README_GHCR_CONTAINERD_DEPLOYMENT.md
git commit -m "update GHCR and containerd deployment guide"
git push origin main
```

不要直接使用 `git add .`，避免把 `.idea/` 或其他本地文件意外提交。

## 4. 将现有 Docker 镜像工作流改造成 GHCR 工作流

GitHub 只识别仓库根目录下的 `.github/workflows/`。

当前仓库已经是独立仓库，因此现有文件已经处于正确位置：

- `.github/workflows/deploy-docker-images.yaml`：旧版 Docker Hub 镜像发布工作流，可以改造成 GHCR 工作流。
- `.github/workflows/deploy-maven-packages.yaml`：发布 Maven Package，与 Kubernetes 镜像部署无关，本次不需要执行。

旧 Docker 工作流不能原样使用，因为它登录 Docker Hub、依赖 `DOCKER_HUB_*` Secrets、仅由 `v1.2.3` 形式的 Git Tag 触发，并且使用了较旧的 Actions 版本。

推荐直接用以下内容替换 `.github/workflows/deploy-docker-images.yaml`：

```yaml
name: Publish evolution images to GHCR

on:
  workflow_dispatch:
    inputs:
      tag:
        description: Immutable image tag, for example log-evolution-v1-20260930
        required: true
        default: log-evolution-v1-20260930
        type: string

permissions:
  contents: read
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    timeout-minutes: 360

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7

      - name: Set up Java 8
        uses: actions/setup-java@v6
        with:
          distribution: temurin
          java-version: "8"
          cache: maven
          cache-dependency-path: "**/pom.xml"

      - name: Package all services
        run: mvn -B -ntp clean package -Dmaven.test.skip=true

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push 46 service images
        env:
          IMAGE_TAG: ${{ inputs.tag }}
        run: |
          set -euo pipefail

          owner=$(printf '%s' "$GITHUB_REPOSITORY_OWNER" | tr '[:upper:]' '[:lower:]')
          source_url="https://github.com/${GITHUB_REPOSITORY}"
          built=0

          for service_dir in ts-*; do
            if [ -d "$service_dir" ] && find "$service_dir" -maxdepth 1 -iname 'Dockerfile' -print -quit | grep -q .; then
              image="ghcr.io/${owner}/${service_dir}:${IMAGE_TAG}"
              echo "Building ${image}"
              docker buildx build \
                --platform linux/amd64 \
                --label "org.opencontainers.image.source=${source_url}" \
                --label "org.opencontainers.image.revision=${GITHUB_SHA}" \
                --tag "$image" \
                --push \
                "$service_dir"
              built=$((built + 1))
            fi
          done

          if [ "$built" -ne 46 ]; then
            echo "Expected 46 images, but built ${built}." >&2
            exit 1
          fi
```

说明：

- 工作流只允许手动触发，避免每次普通提交都构建 46 个镜像。
- 使用仓库自动提供的 `GITHUB_TOKEN`，不需要在仓库中保存个人密码或 PAT。
- Buildx 每构建一个镜像后直接推送到 GHCR，不需要先把全部镜像保存在 runner 的本地 Docker image store 中。
- `org.opencontainers.image.source` 标签用于把 GHCR Package 与源码仓库关联。
- 如果 GitHub Actions 构建时间或磁盘不足，可以后续改成分批矩阵构建。
- 现有 `script/publish-docker-images.sh` 的服务遍历思路仍然可复用；这里在 workflow 中显式使用 `docker buildx build --push`，避免旧脚本依赖 `docker build --push` 的兼容行为。

提交修改后的工作流：

```bash
git add .github/workflows/deploy-docker-images.yaml
git commit -m "publish evolution images to GHCR"
git push origin main
```

## 5. 在 GitHub 上构建并推送镜像

1. 打开仓库页面。
2. 进入 `Actions`。
3. 选择 `Publish evolution images to GHCR`（文件为 `.github/workflows/deploy-docker-images.yaml`）。
4. 点击 `Run workflow`。
5. 输入一个不可变标签，例如：

   ```text
   log-evolution-v1-20260930
   ```

6. 等待 Maven 打包和 46 个镜像推送完成。
7. 查看 Actions 日志，最后必须出现 46 次构建且 Job 为绿色。

如果失败，先修复失败原因再重新执行；不要在发布不完整时直接部署，否则部分 Pod 会出现 `ImagePullBackOff`。

## 6. 选择 GHCR 镜像可见性

Public 和 Private 二选一即可。只有自己或自己的 Kubernetes 集群使用时，建议选择 6.2，让镜像保持 Private。

### 6.1 将 GHCR 镜像设置为 Public

GHCR Package 第一次发布后通常是私有的。对于本指南的“公开拉取”方案，需要将每个业务镜像设为 Public。

操作步骤：

1. 打开 GitHub 个人主页 `https://github.com/20040628`。
2. 进入 `Packages`。
3. 打开一个 Package，例如 `ts-user-service`。
4. 点击 `Package settings`。
5. 在 `Danger Zone` 中选择 `Change visibility` → `Public`。
6. 按 GitHub 提示确认。
7. 对其余业务 Package 重复操作。

注意：GitHub 当前提示 Package 一旦设为 Public，通常不能再改回 Private。公开前检查镜像中没有密钥或配置文件。应用数据库密码应通过 Kubernetes Secret 提供，不应写入镜像。

先把一个镜像设为公开并验证：

```bash
docker pull ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930
```

如果本机没有 Docker，可以直接在 containerd 节点使用 `crictl` 验证，见下一节。

### 6.2 保持 GHCR 镜像为 Private

如果镜像只有自己使用，不需要将 Package 改为 Public。GitHub 源码仓库和 GHCR Package 的可见性相互独立，即使源码仓库是 Public，镜像仍可以保持 Private。

Private 镜像的 GitHub Actions 构建和推送流程不变；区别只在于 Kubernetes 拉取时必须提供凭据。一个 `ghcr-pull-secret` 可以用于当前账号下的全部 46 个业务镜像，containerd 不需要单独执行 `docker login` 或修改 Registry 配置。

#### 6.2.1 创建只读 GitHub Token

在 GitHub 中进入 `Settings` → `Developer settings` → `Personal access tokens` → `Tokens (classic)`，创建一个 Token：

- Token 名称（Note）建议填写 `train-evolution-packages`。这个名称只用于在 GitHub 页面中识别 Token，不参与认证。
- 权限只选择 `read:packages`。
- 设置合适的过期时间，并在到期前更新 Kubernetes Secret。
- 保存生成的 Token 值。不要将它写入 README、YAML、脚本或 Git 仓库。

#### 6.2.2 在 `train-evolution` 中创建拉取凭据

以下命令在可以访问集群的 Linux Bash 终端中执行：

```bash
kubectl create namespace train-evolution --dry-run=client -o yaml | kubectl apply -f -

read -s -p "请输入 GHCR Token: " GHCR_PAT
echo

kubectl create secret docker-registry ghcr-pull-secret \
  --namespace train-evolution \
  --docker-server=ghcr.io \
  --docker-username=20040628 \
  --docker-password="$GHCR_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

unset GHCR_PAT
```

其中：

- `train-evolution-evolution` 是 GitHub 页面中的 Token 名称。
- `GHCR_PAT` 是当前终端中的临时变量名，可以换成其他名字。
- `ghcr-pull-secret` 是 Kubernetes Secret 名称，后续 ServiceAccount 会引用它。
- 执行 `read -s` 后粘贴 Token 并按回车；输入内容不显示属于正常现象。
- `unset GHCR_PAT` 会在 Secret 创建完成后清除终端变量。

Secret 只在所属 Kubernetes namespace 中有效，因此必须创建在 `train-evolution`，不要创建到 `default` 或演化前版本所在的 `train`。

#### 6.2.3 让业务 Pod 自动使用凭据

当前业务 Deployment 没有指定自定义 ServiceAccount，会使用 `train-evolution` 中的默认 ServiceAccount。将 Secret 绑定到它：

```bash
kubectl patch serviceaccount default \
  --namespace train-evolution \
  --type merge \
  --patch '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
```

验证 Secret 和 ServiceAccount：

```bash
kubectl get secret ghcr-pull-secret \
  --namespace train-evolution \
  -o jsonpath='{.type}{"\n"}'

kubectl get serviceaccount default \
  --namespace train-evolution \
  -o jsonpath='{.imagePullSecrets}{"\n"}'
```

输出应分别包含：

```text
kubernetes.io/dockerconfigjson
[{"name":"ghcr-pull-secret"}]
```

#### 6.2.4 通过 Kubernetes 验证 Private 镜像拉取

Secret 和 ServiceAccount 配置完成后，创建一个新 Pod 测试。不要仅以已有 Pod 继续运行为依据，因为节点上可能已有镜像缓存。

```bash
kubectl delete pod ghcr-private-pull-test \
  --namespace train-evolution \
  --ignore-not-found

kubectl run ghcr-private-pull-test \
  --namespace train-evolution \
  --image=ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930 \
  --restart=Never \
  --command -- sh -c 'java -version'

kubectl get pod ghcr-private-pull-test -n train-evolution -w
kubectl logs ghcr-private-pull-test -n train-evolution
kubectl delete pod ghcr-private-pull-test -n train-evolution
```

如果出现 `ImagePullBackOff`，使用下面的命令检查事件，并确认 Token 尚未过期、具有 `read:packages` 权限，而且账号 `20040628` 对 Package 有读取权限：

```bash
kubectl describe pod ghcr-private-pull-test -n train-evolution
kubectl get events -n train-evolution --sort-by=.lastTimestamp
```

完成以上配置后，第 8 节的 `make deploy` 命令无需变化。

## 7. 验证 containerd 节点能够访问 GHCR

GHCR 使用标准 HTTPS 和 OCI Registry API。Public 镜像可以匿名拉取；Private 镜像由 Kubernetes `imagePullSecret` 提供认证。两种方案正常情况下都不需要修改 containerd 配置。

### 7.1 检查网络

在每个可能调度业务 Pod 的节点上执行：

```bash
curl -I https://ghcr.io/v2/
```

返回 `401 Unauthorized` 也能说明网络和 TLS 已连通；Registry 根端点要求认证是正常行为，公开镜像的具体 manifest/layer 仍可匿名拉取。

### 7.2 使用 CRI 匿名拉取测试（仅 Public）

选择 6.1 Public 方案时，在一个工作节点上执行：

```bash
sudo crictl info
sudo crictl pull ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930
sudo crictl images | grep ts-user-service
```

`crictl` 通过 CRI 与 Kubernetes 使用的 containerd 通信，比只使用 `ctr` 更接近 kubelet 的真实拉取路径。

Private 镜像不能使用上述匿名命令验证；选择 6.2 时直接使用 6.2.4 的 Kubernetes Secret 拉取测试。

如果必须使用 `ctr` 排查：

```bash
sudo ctr -n k8s.io images pull ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930
```

这里的 `-n k8s.io` 是 containerd namespace，不是 Kubernetes namespace。

只有在使用企业代理、Registry Mirror 或自签名 CA 时，才需要配置 `/etc/containerd/certs.d/ghcr.io/hosts.toml`。不要主动关闭 TLS 校验。

### 7.3 通过 Kubernetes 做最终拉取测试

选择 6.1 Public 方案时执行下面的匿名拉取测试。选择 6.2 Private 方案时，6.2.4 已经完成带 Secret 的等价测试，不需要重复执行本段。

```bash
kubectl create namespace train-evolution --dry-run=client -o yaml | kubectl apply -f -

kubectl run ghcr-pull-test \
  --namespace train-evolution \
  --image=ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930 \
  --restart=Never \
  --command -- sh -c 'java -version'

kubectl get pod ghcr-pull-test -n train-evolution -w
kubectl logs ghcr-pull-test -n train-evolution
kubectl delete pod ghcr-pull-test -n train-evolution
```

无论选择 Public 还是 Private，都只有在对应的 Kubernetes 拉取测试成功后，再部署完整系统。

## 8. 部署演化版 Train Ticket

在能够访问 Kubernetes 集群的部署控制机上：

```bash
git clone https://github.com/20040628/train-ticket-evolution.git
cd train-ticket-evolution

make deploy \
  Namespace=train-evolution \
  Repo=ghcr.io/20040628 \
  Tag=log-evolution-v2-20260930 \
  DeployArgs="--with-tracing"
```

部署脚本会：

1. 只允许使用 `train-evolution` namespace。
2. 在该 namespace 中部署独立的 Nacos、Nacos MySQL、RabbitMQ 和 Train Ticket MySQL。
3. 将普通与 SkyWalking 两套 Deployment 样例中的业务镜像替换为：

   ```text
   ghcr.io/20040628/<服务名>:log-evolution-v2-20260930
   ```

4. 部署带 SkyWalking Agent 的业务服务。
5. 在 `train-evolution` 中部署独立的 SkyWalking 和 Elasticsearch。
6. 保持 Gateway、UI、Nacos 和 SkyWalking UI 为 `ClusterIP`，不占用原 `train` 环境的 NodePort。
7. 不重复部署集群级 Prometheus/Grafana 清单。

如果选择 6.1 的 Public 方案，不需要创建 `imagePullSecret`。如果选择 6.2 的 Private 方案，必须先创建并绑定 `ghcr-pull-secret`；部署命令本身保持不变。

## 9. 检查部署结果

观察 Pod：

```bash
kubectl get pods -n train-evolution -o wide
kubectl get statefulset,deployment,service,pvc -n train-evolution
kubectl get events -n train-evolution --sort-by=.lastTimestamp
```

查看实际使用的镜像：

```bash
kubectl get pods -n train-evolution \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

输出中的业务镜像都应满足：

```text
ghcr.io/20040628/ts-*:log-evolution-v1-20260930
```

确认两个 namespace 同时存在：

```bash
kubectl get pods -n train
kubectl get pods -n train-evolution
```

确认演化环境的 Nacos、MySQL、RabbitMQ 都位于 `train-evolution`：

```bash
kubectl get pod,svc,configmap,secret -n train-evolution | grep -E 'nacos|mysql|rabbitmq'
```

## 10. 访问系统

演化版入口使用 `ClusterIP`，不会与原系统的固定 NodePort 冲突。

转发 UI：

```bash
kubectl port-forward -n train-evolution service/ts-ui-dashboard 8081:8080
```

浏览器访问：

```text
http://localhost:8081
```

转发 SkyWalking UI：

```bash
kubectl port-forward -n train-evolution service/skywalking-ui 8082:8080
```

浏览器访问：

```text
http://localhost:8082
```

如果需要长期对外访问，应为演化环境配置独立 Ingress 域名，而不是恢复与 `train` 相同的 NodePort。

## 11. 常见错误与排查

### 11.1 构建时报 `java:8-jre: not found`

旧版业务 Dockerfile 使用的 `java:8-jre` 标签已经不可用。仓库中的 41 个 Java 服务应统一使用仍在维护的 Eclipse Temurin Java 8 JRE：

```dockerfile
FROM eclipse-temurin:8-jre-jammy
```

修改后提交并推送代码，然后从包含该提交的分支重新执行一次 `Run workflow`；不要直接对旧运行点击 `Re-run jobs`，因为旧运行仍使用旧提交。这里可以继续使用原标签。当前错误发生在第一个镜像推送之前，不会留下不完整的同标签镜像集合。

### 11.2 构建时报 `libgl1-mesa-glx has no installation candidate`

`ts-avatar-service` 的旧 Dockerfile 同时存在两个兼容性问题：

- `python:3` 是浮动标签，当前会使用远新于项目依赖的 Python 版本。
- 新版 Debian 已不再提供 `libgl1-mesa-glx`，OpenGL 兼容运行库应安装 `libgl1`。

仓库已将该服务固定到与现有 Python 依赖兼容的版本，并合并 apt 安装步骤：

```dockerfile
FROM python:3.9.25-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
```

工作流逐个推送镜像，因此在 `ts-avatar-service` 失败前可能已经推送了排在它前面的镜像。提交修复后，应从新提交执行一次新的 `Run workflow`，并使用新标签（例如 `log-evolution-v2-20260930`）；完整工作流成功前不要部署该标签。

### 11.3 MySQL 显示 `partitioned roll out complete` 后 `make` 返回错误 1

如果日志停在下面的位置：

```text
partitioned roll out complete: 3 new pods have been updated...
make: *** [Makefile:38: deploy] Error 1
```

这表示 MySQL StatefulSet 已经就绪，真正失败的是紧接着生成业务数据库 Secret 的步骤。旧脚本直接执行 `rm secret.yaml`；该文件是部署时生成且不纳入 Git 的文件，首次部署时不存在，`rm` 会返回 1，而 `deploy.sh` 的 `set -e` 会因此终止整个流程。

仓库修复包括：

- 使用 `: > secret.yaml` 创建或清空文件，不再因文件首次不存在而失败。
- 修正单库/独立数据库模式的条件判断。
- Helm release 已存在时直接复用，使中断后的部署能够安全重试，不会出现 `cannot re-use a name that is still in use`。

不要执行 `make reset-deploy`，也不需要删除已经就绪的 MySQL Pod 或 PVC。拉取修复后直接重新执行相同部署命令：

```bash
git pull --ff-only

helm list -n train-evolution
kubectl get statefulset,pod -n train-evolution

make deploy \
  Namespace=train-evolution \
  Repo=ghcr.io/20040628 \
  Tag=log-evolution-v2-20260930 \
  DeployArgs="--with-tracing"
```

脚本会跳过已经存在的 `nacosdb`、`nacos`、`rabbitmq` 和 `tsdb` Helm release，重新确认它们就绪，然后从 Secret 和业务服务部署阶段继续。

### 11.4 `ImagePullBackOff` 或 `ErrImagePull`

```bash
kubectl describe pod <pod-name> -n train-evolution
kubectl get events -n train-evolution --sort-by=.lastTimestamp
```

常见原因：

- GHCR Package 是 Private，但 `ghcr-pull-secret` 缺失、无权限或已经过期。
- 镜像标签拼写错误。
- Actions 只发布了部分镜像。
- 节点不能访问 `ghcr.io:443`。
- 节点 DNS、代理或证书配置异常。

### 11.5 `manifest unknown`

镜像或标签不存在。打开 GitHub Package 页面检查标签，并确认部署命令中的 `Tag` 与 Actions 输入完全一致。

### 11.6 `no matching manifest for linux/arm64`

节点是 `arm64`，但当前 Actions 只构建了 `linux/amd64`。需要使用 Buildx 构建多架构镜像，并确认所有基础镜像都支持目标架构。

### 11.7 `x509: certificate signed by unknown authority`

通常是企业 HTTPS 代理或自定义 CA 导致。应将可信 CA 配置到 containerd 的 registry hosts 配置中，不要使用 `skip_verify = true` 作为长期方案。

### 11.8 Pod 一直 `Pending`

```bash
kubectl describe pod <pod-name> -n train-evolution
kubectl get pvc -n train-evolution
kubectl get storageclass
```

如果 PVC 为 `Pending`，检查默认 StorageClass 和动态供应器。

### 11.9 重新发布后仍运行旧镜像

本项目使用 `imagePullPolicy: IfNotPresent`。不要覆盖已使用的标签；每次发布使用新标签，例如：

```text
log-evolution-v1-20260930
log-evolution-v2-20261001
```

然后使用新标签重新执行 `make deploy`。

## 12. 回收演化环境

只清理演化环境：

```bash
cd train-ticket-evolution
make reset-deploy Namespace=train-evolution
```

脚本会拒绝清理 `train` namespace。

执行前仍应确认当前集群：

```bash
kubectl config current-context
kubectl get pods -n train-evolution
```

## 13. Private GHCR 凭据维护

Private 镜像的首次配置和验证见 6.2。Token 到期或被撤销后，使用新的 Token 重新执行 6.2.2 中的 `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` 命令，即可原地更新 `ghcr-pull-secret`。不要删除正在运行的 Pod，直到新的拉取测试成功。

## 14. 官方文档

- [GitHub Container Registry 使用说明](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [使用 GitHub Actions 发布 Docker/OCI 镜像](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
- [配置 GitHub Package 权限和可见性](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
- [GitHub Actions 的 `GITHUB_TOKEN`](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication)
- [Kubernetes 镜像、镜像名称与拉取策略](https://kubernetes.io/docs/concepts/containers/images/)
- [Kubernetes 从私有 Registry 拉取镜像](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
- [使用 `crictl` 调试 Kubernetes 节点](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/)
- [containerd Registry hosts 配置](https://github.com/containerd/containerd/blob/main/docs/hosts.md)
- [containerd CRI Registry 配置](https://github.com/containerd/containerd/blob/main/docs/cri/registry.md)
- [Helm install 命令](https://helm.sh/docs/helm/helm_install/)

## 15. 最终执行清单

- [x] 源码已推送到 `20040628/train-ticket-evolution`。
- [ ] 已将仓库根目录 `.github/workflows/deploy-docker-images.yaml` 改造成 GHCR 工作流。
- [ ] Actions 使用 Java 8 成功完成 Maven 打包。
- [ ] Actions 成功发布全部 46 个业务镜像。
- [ ] 部署使用唯一且非 `latest` 的标签。
- [ ] 已选择一种镜像可见性方案：全部 Package 为 Public，或全部保持 Private 并配置 `ghcr-pull-secret`。
- [ ] Public 匿名拉取测试，或 Private Kubernetes Secret 拉取测试已经成功。
- [ ] 所有 Kubernetes 节点能够访问 `ghcr.io:443`。
- [ ] 集群有默认 StorageClass 和足够资源。
- [ ] 当前 kubeconfig context 已核对。
- [ ] `train` 中的演化前版本仍正常运行。
- [ ] 演化版部署命令使用 `Namespace=train-evolution`。
- [ ] 演化版业务镜像均来自 `ghcr.io/20040628/*:<唯一标签>`。
- [ ] Gateway、UI、Nacos、SkyWalking UI 未占用原环境 NodePort。
- [ ] Nacos、MySQL、RabbitMQ 和 SkyWalking 数据与 `train` 环境隔离。
