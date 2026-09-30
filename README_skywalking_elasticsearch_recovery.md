# SkyWalking / Elasticsearch 故障复盘与修复记录

## 1. 背景

Train Ticket Kubernetes 环境中使用 SkyWalking + Elasticsearch 进行链路追踪与指标存储。

本次环境中的主要组件：

- Namespace：`train`
- SkyWalking OAP：`apache/skywalking-oap-server:8.5.0-es7`
- SkyWalking UI：`apache/skywalking-ui:8.5.0`
- Storage：`elasticsearch7`
- Elasticsearch Service：`elasticsearch:9200`

SkyWalking ConfigMap：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: skywalking-cm
  namespace: train
data:
  CORE_GRPC_PORT: "11800"
  CORE_REST_PORT: "12800"
  STORAGE: elasticsearch7
  STORAGE_ES_CLUSTER_NODES: elasticsearch:9200
```

## 2. 故障现象

SkyWalking OAP Pod 虽然显示 `Running`，但日志持续出现：

```text
index_not_found_exception
no such index [sw_instance_traffic]
```

同时还出现过：

```text
no such index [sw_service_traffic]
no such index [sw_metrics-doubleavg]
```

典型请求为：

```text
POST /sw_instance_traffic/_search
```

Elasticsearch 返回：

```text
HTTP/1.1 404 Not Found
index_not_found_exception
```

SkyWalking 健康检查同时出现：

```text
HealthCheckMetrics - Health check fails
```

## 3. Elasticsearch 中的异常状态

检查：

```bash
ES=$(kubectl get pod -n train -l run=elasticsearch   -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/indices/sw*?v'
```

可以看到大量带日期后缀的 SkyWalking 索引，例如：

```text
sw_instance_traffic-20260809
sw_service_traffic-20260809
sw_metrics-doubleavg-20260809
sw_metrics-longavg-20260809
sw_segment-20260809
sw_log-20260809
```

但 OAP 仍然会读取：

```text
sw_instance_traffic
sw_service_traffic
sw_metrics-doubleavg
```

最终产生 404。

检查 alias：

```bash
kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/aliases?v&s=alias'
```

当时没有可用的 SkyWalking alias。

## 4. 根因分析

本次问题不是 Elasticsearch 网络不可达，也不是 `SW_STORAGE` 配错。

因为 OAP 能正常向 Elasticsearch 执行 bulk 写入，说明 OAP 与 ES 的连接是正常的。

真正的问题是：

> SkyWalking 在 Elasticsearch 中的 storage/index 状态不完整或不一致，导致 OAP 运行时访问不存在的逻辑索引并持续报 `index_not_found_exception`。

单纯执行：

```bash
kubectl rollout restart deployment skywalking -n train
```

不能恢复已经异常的 Elasticsearch storage 状态。

最终采用的修复思路是：

> 停止 OAP，删除现有异常的 `sw*` 索引，再重新启动 OAP，让 SkyWalking 基于干净的 Elasticsearch 状态重新创建所需索引。

## 5. 最终修复方法

> 注意：以下操作会删除 Elasticsearch 中已有的 SkyWalking Trace、Metrics、Log、Alarm 等历史数据，但不会删除 Train Ticket 的 MySQL 等业务数据。

### 第一步：停止 SkyWalking OAP

```bash
kubectl scale deployment skywalking -n train --replicas=0
```

确认：

```bash
kubectl get pods -n train | grep skywalking
```

### 第二步：获取 Elasticsearch Pod

```bash
ES=$(kubectl get pod -n train -l run=elasticsearch   -o jsonpath='{.items[0].metadata.name}')

echo "$ES"
```

### 第三步：检查现有 SkyWalking 索引

```bash
kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/indices/sw*?v'
```

### 第四步：删除所有 SkyWalking 索引

```bash
kubectl exec -n train "$ES" --   curl -X DELETE 'localhost:9200/sw*'
```

正常返回：

```json
{"acknowledged":true}
```

再次确认：

```bash
kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/indices/sw*?v'
```

此时原来的 `sw_*` 索引应已清空。

### 第五步：重新启动 SkyWalking OAP

```bash
kubectl scale deployment skywalking -n train --replicas=1
```

检查：

```bash
kubectl get pods -n train | grep skywalking
```

等待 OAP 变为：

```text
1/1 Running
```

### 第六步：确认索引重新创建

```bash
kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/indices/sw*?v&s=index'
```

### 第七步：确认错误消失

```bash
kubectl logs -n train -l app=skywalking --since=5m |   grep 'index_not_found_exception'
```

如果没有输出，说明该问题已经恢复。

## 6. 第二个问题：SkyWalking UI OOMKilled

恢复 OAP 后，SkyWalking UI 又出现：

```text
State: Waiting
Reason: CrashLoopBackOff

Last State: Terminated
Reason: OOMKilled
Exit Code: 137
```

当时 UI 资源限制为：

```text
Limits:
  cpu:     2
  memory:  1Gi
```

`OOMKilled + Exit Code 137` 表明 UI 容器实际内存超过 Kubernetes 设置的 `1Gi` memory limit，被 kubelet 强制终止。

### 修复方法

将 UI memory limit 从 `1Gi` 提高到 `2Gi`：

```bash
kubectl patch deployment skywalking-ui -n train   --type='json'   -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"}
  ]'
```

等待更新：

```bash
kubectl rollout status deployment skywalking-ui -n train
```

检查：

```bash
kubectl get pods -n train | grep skywalking
```

正常应为：

```text
skywalking-xxxxx      1/1   Running
skywalking-ui-xxxxx   1/1   Running
```

如果仍然 OOM，可继续提高到 `3Gi`：

```bash
kubectl patch deployment skywalking-ui -n train   --type='json'   -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"}
  ]'
```

## 7. 最终修复流程总结

### SkyWalking Elasticsearch 索引异常

```bash
# 1. 停止 OAP
kubectl scale deployment skywalking -n train --replicas=0

# 2. 获取 Elasticsearch Pod
ES=$(kubectl get pod -n train -l run=elasticsearch   -o jsonpath='{.items[0].metadata.name}')

# 3. 删除异常 SkyWalking storage
kubectl exec -n train "$ES" --   curl -X DELETE 'localhost:9200/sw*'

# 4. 重新启动 OAP
kubectl scale deployment skywalking -n train --replicas=1

# 5. 检查错误
kubectl logs -n train -l app=skywalking --since=5m |   grep 'index_not_found_exception'
```

### SkyWalking UI OOM

```bash
kubectl patch deployment skywalking-ui -n train   --type='json'   -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"}
  ]'
```

## 8. 为什么单纯重启 OAP 没有解决

曾尝试：

```bash
kubectl rollout restart deployment skywalking -n train
```

新的 OAP Pod 能启动，但 `index_not_found_exception` 仍然存在。

原因是：

> 重启 OAP 只会重新启动进程，并不会自动修复 Elasticsearch 中已经处于不一致状态的 SkyWalking storage 数据。

因此最终采用：

```text
停止 OAP
   ↓
删除异常 sw* storage
   ↓
重新启动 OAP
   ↓
让 SkyWalking 基于干净 ES 状态重新初始化
```

## 9. 后续建议

### 9.1 给 Elasticsearch 配置持久化存储

Train Ticket 仓库中的 Elasticsearch 示例部署没有为：

```text
/usr/share/elasticsearch/data
```

配置 PVC。

建议挂载 PersistentVolumeClaim，例如：

```yaml
volumeMounts:
  - name: elasticsearch-data
    mountPath: /usr/share/elasticsearch/data

volumes:
  - name: elasticsearch-data
    persistentVolumeClaim:
      claimName: elasticsearch-pvc
```

否则 Elasticsearch Pod 被重新创建时存在历史数据丢失风险。

### 9.2 持续关注 OOM

```bash
kubectl get pods -n train
```

如果 Restart Count 持续增长：

```bash
kubectl describe pod <pod-name> -n train
```

重点检查：

```text
Reason: OOMKilled
Exit Code: 137
```

### 9.3 不建议手工创建 SkyWalking 空索引

不要看到：

```text
no such index [sw_instance_traffic]
```

就直接：

```bash
curl -X PUT localhost:9200/sw_instance_traffic
```

因为 SkyWalking 对 Elasticsearch index 有自己的 mapping 和 storage schema，手工创建空 index 可能导致字段类型或 mapping 不正确。

## 10. 快速诊断命令

### 检查 SkyWalking Pod

```bash
kubectl get pods -n train | grep skywalking
```

### 检查 OAP Elasticsearch 错误

```bash
kubectl logs -n train -l app=skywalking --since=10m |   grep 'index_not_found_exception'
```

### 检查 SkyWalking 索引

```bash
ES=$(kubectl get pod -n train -l run=elasticsearch   -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/indices/sw*?v'
```

### 检查 alias

```bash
kubectl exec -n train "$ES" --   curl -s 'localhost:9200/_cat/aliases?v&s=alias'
```

### 检查 OOM

```bash
kubectl describe pod <pod-name> -n train |   grep -A10 -E 'State:|Last State:|Limits:'
```

## 11. 一句话总结

> SkyWalking OAP 与 Elasticsearch 中已有的 SkyWalking storage 状态不一致，导致 OAP 持续访问不存在的索引并产生 `index_not_found_exception`；停止 OAP、删除异常的 `sw*` Elasticsearch 数据并重新启动 OAP 后恢复。随后 SkyWalking UI 因 `1Gi` 内存限制发生 `OOMKilled`，将 UI memory limit 提高到 `2Gi` 后恢复正常。
