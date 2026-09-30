# Train Ticket 演化版：发布公开镜像并部署到 containerd Kubernetes

最后核对日期：2026-09-30

本指南用于完成以下目标：

- 将 `train-ticket-evolution` 的源码保存到 GitHub 仓库 `20040628/train-ticket-myself`。
- 使用 GitHub Actions 编译项目并构建 46 个业务镜像。
- 将镜像发布到 GitHub Container Registry（GHCR）。
- 将 GHCR 镜像设置为公开，使 Kubernetes 节点无须镜像凭据即可拉取。
- 在远程、多节点、运行时为 containerd 的 Kubernetes 集群中，将演化版部署到 `train-evolution` namespace。
- 保留演化前版本在 `train` namespace 中继续运行。

## 1. 先理解源码、镜像仓库和 containerd 的关系

完整链路如下：

```text
GitHub 源码仓库
  └─ GitHub Actions：Maven 编译 + Docker/OCI 镜像构建
       └─ GHCR 公开镜像：ghcr.io/20040628/<服务名>:<标签>
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

- GitHub 仓库：`https://github.com/20040628/train-ticket-myself`
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

## 3. 上传源码到 GitHub

源码直接按照现有文件夹结构使用 Git 提交，不要压缩成 ZIP，也不要执行 `docker save` 后把 tar 文件提交进仓库。

建议先检查：

```bash
cd train-ticket-myself
git remote -v
git status --short
```

当前项目的远程仓库应为：

```text
https://github.com/20040628/train-ticket-myself.git
```

不要提交以下内容：

- `.idea/`
- 各服务的 `target/`
- `*.tar` 镜像文件
- kubeconfig、Token、密码、私钥
- 仅供本地 AI 对话交接使用的文件，除非确认需要公开

在确认变更后提交源码。示例：

```bash
git add -u train-ticket-evolution
git add train-ticket-evolution/README_GHCR_CONTAINERD_DEPLOYMENT.md
git commit -m "add isolated evolution deployment and GHCR guide"
git push origin main
```

不要直接使用 `git add .`，避免把 `.idea/` 或其他本地文件意外提交。

## 4. 创建 GitHub Actions 镜像发布工作流

GitHub 只识别仓库根目录下的 `.github/workflows/`。

本仓库中的演化项目位于子目录，因此：

- `train-ticket-evolution/.github/workflows/` 中的旧工作流不会被当前父仓库直接执行。
- 应在仓库根目录创建 `.github/workflows/publish-evolution-images.yml`。

文件内容如下：

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

    defaults:
      run:
        working-directory: train-ticket-evolution

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7

      - name: Set up Java 8
        uses: actions/setup-java@v6
        with:
          distribution: temurin
          java-version: "8"
          cache: maven
          cache-dependency-path: train-ticket-evolution/**/pom.xml

      - name: Package all services
        run: mvn -B -ntp clean package -Dmaven.test.skip=true

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
              docker build \
                --label "org.opencontainers.image.source=${source_url}" \
                --label "org.opencontainers.image.revision=${GITHUB_SHA}" \
                --tag "$image" \
                "$service_dir"
              docker push "$image"
              docker image rm "$image"
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
- 每构建并推送一个镜像后删除本地镜像，降低 GitHub runner 磁盘压力。
- `org.opencontainers.image.source` 标签用于把 GHCR Package 与源码仓库关联。
- 如果 GitHub Actions 构建时间或磁盘不足，可以后续改成分批矩阵构建。

将工作流提交到 GitHub：

```bash
git add .github/workflows/publish-evolution-images.yml
git commit -m "add GHCR publishing workflow"
git push origin main
```

## 5. 在 GitHub 上构建并推送镜像

1. 打开仓库页面。
2. 进入 `Actions`。
3. 选择 `Publish evolution images to GHCR`。
4. 点击 `Run workflow`。
5. 输入一个不可变标签，例如：

   ```text
   log-evolution-v1-20260930
   ```

6. 等待 Maven 打包和 46 个镜像推送完成。
7. 查看 Actions 日志，最后必须出现 46 次构建且 Job 为绿色。

如果失败，先修复失败原因再重新执行；不要在发布不完整时直接部署，否则部分 Pod 会出现 `ImagePullBackOff`。

## 6. 将 GHCR 镜像设置为公开

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

## 7. 验证 containerd 节点能够访问 GHCR

GHCR 使用标准 HTTPS 和 OCI Registry API。对于公开 GHCR，正常情况下不需要修改 containerd 配置。

### 7.1 检查网络

在每个可能调度业务 Pod 的节点上执行：

```bash
curl -I https://ghcr.io/v2/
```

返回 `401 Unauthorized` 也能说明网络和 TLS 已连通；Registry 根端点要求认证是正常行为，公开镜像的具体 manifest/layer 仍可匿名拉取。

### 7.2 使用 CRI 拉取测试

在一个工作节点上执行：

```bash
sudo crictl info
sudo crictl pull ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930
sudo crictl images | grep ts-user-service
```

`crictl` 通过 CRI 与 Kubernetes 使用的 containerd 通信，比只使用 `ctr` 更接近 kubelet 的真实拉取路径。

如果必须使用 `ctr` 排查：

```bash
sudo ctr -n k8s.io images pull ghcr.io/20040628/ts-user-service:log-evolution-v1-20260930
```

这里的 `-n k8s.io` 是 containerd namespace，不是 Kubernetes namespace。

只有在使用企业代理、Registry Mirror 或自签名 CA 时，才需要配置 `/etc/containerd/certs.d/ghcr.io/hosts.toml`。不要为了公开 GHCR 主动关闭 TLS 校验。

### 7.3 通过 Kubernetes 做最终拉取测试

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

只有该测试成功后，再部署完整系统。

## 8. 部署演化版 Train Ticket

在能够访问 Kubernetes 集群的部署控制机上：

```bash
cd train-ticket-myself/train-ticket-evolution

make deploy \
  Namespace=train-evolution \
  Repo=ghcr.io/20040628 \
  Tag=log-evolution-v1-20260930 \
  DeployArgs="--with-tracing"
```

部署脚本会：

1. 只允许使用 `train-evolution` namespace。
2. 在该 namespace 中部署独立的 Nacos、Nacos MySQL、RabbitMQ 和 Train Ticket MySQL。
3. 将普通与 SkyWalking 两套 Deployment 样例中的业务镜像替换为：

   ```text
   ghcr.io/20040628/<服务名>:log-evolution-v1-20260930
   ```

4. 部署带 SkyWalking Agent 的业务服务。
5. 在 `train-evolution` 中部署独立的 SkyWalking 和 Elasticsearch。
6. 保持 Gateway、UI、Nacos 和 SkyWalking UI 为 `ClusterIP`，不占用原 `train` 环境的 NodePort。
7. 不重复部署集群级 Prometheus/Grafana 清单。

由于镜像是公开的，不需要创建 `imagePullSecret`，也不需要给 Deployment 增加 `imagePullSecrets`。

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

### 11.1 `ImagePullBackOff` 或 `ErrImagePull`

```bash
kubectl describe pod <pod-name> -n train-evolution
kubectl get events -n train-evolution --sort-by=.lastTimestamp
```

常见原因：

- GHCR Package 仍是 Private。
- 镜像标签拼写错误。
- Actions 只发布了部分镜像。
- 节点不能访问 `ghcr.io:443`。
- 节点 DNS、代理或证书配置异常。

### 11.2 `manifest unknown`

镜像或标签不存在。打开 GitHub Package 页面检查标签，并确认部署命令中的 `Tag` 与 Actions 输入完全一致。

### 11.3 `no matching manifest for linux/arm64`

节点是 `arm64`，但当前 Actions 只构建了 `linux/amd64`。需要使用 Buildx 构建多架构镜像，并确认所有基础镜像都支持目标架构。

### 11.4 `x509: certificate signed by unknown authority`

通常是企业 HTTPS 代理或自定义 CA 导致。应将可信 CA 配置到 containerd 的 registry hosts 配置中，不要使用 `skip_verify = true` 作为长期方案。

### 11.5 Pod 一直 `Pending`

```bash
kubectl describe pod <pod-name> -n train-evolution
kubectl get pvc -n train-evolution
kubectl get storageclass
```

如果 PVC 为 `Pending`，检查默认 StorageClass 和动态供应器。

### 11.6 重新发布后仍运行旧镜像

本项目使用 `imagePullPolicy: IfNotPresent`。不要覆盖已使用的标签；每次发布使用新标签，例如：

```text
log-evolution-v1-20260930
log-evolution-v2-20261001
```

然后使用新标签重新执行 `make deploy`。

## 12. 回收演化环境

只清理演化环境：

```bash
cd train-ticket-myself/train-ticket-evolution
make reset-deploy Namespace=train-evolution
```

脚本会拒绝清理 `train` namespace。

执行前仍应确认当前集群：

```bash
kubectl config current-context
kubectl get pods -n train-evolution
```

## 13. 私有 GHCR 的备用方案

如果以后不再公开镜像，可以将 Package 保持 Private，并在 `train-evolution` 中配置拉取凭据。但不要把 Token 写进 YAML 或 Git。

示例：

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace train-evolution \
  --docker-server=ghcr.io \
  --docker-username=20040628 \
  --docker-password='<具有 read:packages 权限的 Token>'

kubectl patch serviceaccount default \
  --namespace train-evolution \
  --type merge \
  --patch '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
```

公开镜像方案不需要执行这一节。

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

- [ ] 源码已推送到 `20040628/train-ticket-myself`。
- [ ] 工作流位于仓库根目录 `.github/workflows/publish-evolution-images.yml`。
- [ ] Actions 使用 Java 8 成功完成 Maven 打包。
- [ ] Actions 成功发布全部 46 个业务镜像。
- [ ] 部署使用唯一且非 `latest` 的标签。
- [ ] 所有 GHCR Package 已设为 Public。
- [ ] 未登录状态或 containerd 节点能够拉取测试镜像。
- [ ] 所有 Kubernetes 节点能够访问 `ghcr.io:443`。
- [ ] 集群有默认 StorageClass 和足够资源。
- [ ] 当前 kubeconfig context 已核对。
- [ ] `train` 中的演化前版本仍正常运行。
- [ ] 演化版部署命令使用 `Namespace=train-evolution`。
- [ ] 演化版业务镜像均来自 `ghcr.io/20040628/*:<唯一标签>`。
- [ ] Gateway、UI、Nacos、SkyWalking UI 未占用原环境 NodePort。
- [ ] Nacos、MySQL、RabbitMQ 和 SkyWalking 数据与 `train` 环境隔离。
