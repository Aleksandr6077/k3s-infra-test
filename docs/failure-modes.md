Каждый сценарий описывается по одной схеме:

### FM-N: Название

**Триггер**: что происходит (событие, а не симптом).
**Blast radius**: что именно деградирует/падает.
**Detection**: как мы узнаём (алерт, метрика, глазом).
**Mitigation**: что делаем немедленно (5–15 мин).
**Recovery**: как восстанавливаемся полностью.
**Prevention**: что меняем, чтобы не повторилось.
**Owner**: кто отвечает.

---

### FM-1: Preemption одного master

**Триггер**: Yandex отзывает preemptible ВМ (capacity, maintenance).
**Blast radius**: 1 из 3 master недоступен. Кворум есть (2/3), 
API работает. Нагрузка на оставшиеся 2 растёт.
**Detection**: 
- Alert `up{job="kube-apiserver"} == 0` (5 min)
- Yandex Monitoring: instance status = STOPPED
**Mitigation**:
1. Проверить `kubectl get nodes` — нода NotReady.
2. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` — 
   если ещё доступна.
3. Если preempted жёстко — нода просто исчезает, drain не нужен.
**Recovery**:
1. Ansible: пересоздать ноду — `terraform apply -target=...`.
2. Дождаться `Ready` — join в etcd кворум.
3. Проверить `kubectl get --raw /healthz/etcd`.
4. Проверить Longhorn replicas: `kubectl -n longhorn-system get replicas`.
**Prevention**:
- Переход на non-preemptible (P0 для прода).
- etcd snapshot раз в 5 мин в S3.
**Owner**: @Aleksandr6077
**Реальный инцидент**: нет (только симуляция).

---

### FM-2: Preemption двух masters одновременно

**Триггер**: Yandex отзывает две preemptible ВМ в окне < 5 мин.
**Blast radius**: **Кворум потерян**. API недоступен. Кластер 
переходит в read-only (kubelet работает, но scheduler/apiserver — нет).
**Detection**: 
- Alert `kube_pod_status_ready{namespace="kube-system"} < 2` (critical)
- kubectl таймаутит.
**Mitigation**:
1. **Не паниковать.** Данные etcd не потеряны — это Raft, не master-slave.
2. Поднять ноду вручную или через terraform.
3. Дождаться join.
**Recovery**:
1. `terraform apply` — пересоздать 1 или 2 ноды.
2. Ansible: `--server <alive_master>:6443` для join.
3. Если обе ноды потеряли данные etcd — restore из snapshot:
   `systemctl stop k3s && k3s server --cluster-reset --cluster-reset-restore-path=...`
4. Проверить кворум.
**Prevention**:
- **Non-preemptible** (обязательно для прода).
- Anti-affinity: мастера уже в разных зонах — хорошо.
**Owner**: @Aleksandr6077
**Реальный инцидент**: нет.

---

### FM-3: Bastion preempted в момент деплоя

**Триггер**: bastion отозван во время `make ansible-deploy` или 
активной SSH-сессии.
**Blast radius**: CI падает, kubectl отваливается, Ansible timeout.
**Detection**: 
- `make ansible-deploy` fail: `Timeout when waiting for 22`.
- `kubectl` — connection refused на 6443.
**Mitigation**:
1. `terraform apply -target=yandex_compute_instance.bastion`.
2. Получить новый публичный IP: `terraform output bastion_public_ip`.
3. Обновить `hosts.ini` — `make up` перегенерирует.
4. Перезапустить `make ansible-deploy`.
**Recovery**: 5 минут.
**Prevention**:
- Bastion — **non-preemptible**.
- Второй bastion в другой зоне за NLB (для прода).
- Managed bastion (Yandex Cloud Bastion).
**Owner**: @Aleksandr6077
**Реальный инцидент**: да, во время Этапа 13 (перенос bastion из a в b).

---

### FM-4: Отказ зоны `ru-central1-a`

**Триггер**: сбой зоны Yandex (электричество, сеть, maintenance).
**Blast radius**: 
- -1 master (a) → кворум 2/3 сохраняется.
- -1 worker (a) → Longhorn теряет 1 из 2 реплик.
- Bastion не в a — хорошо.
**Detection**:
- Alert: `kube_node_status_condition{condition="Ready",status="false"} == 1`.
- Yandex incident notification.
**Mitigation**:
1. Проверить `kubectl get nodes -o wide` — master-a NotReady.
2. **Не трогать** Longhorn: он сам ребалансирует после возврата.
3. Убедиться, что приложение на worker-b работает.
**Recovery**:
- Yandex восстанавливает зону. Если > 1ч — пересоздать ноду.
**Prevention**:
- Уже multi-zonal.
- Для прода: 3+ реплики Longhorn (сейчас 2).
**Owner**: @Aleksandr6077
**Реальный инцидент**: да, 2026-XX — зона `a` была недоступна, 
bastion перенесён в `b`.

---

### FM-5: Потеря PVC `local-path` (Loki / Prometheus)

**Триггер**: под удалён, нода пересоздана, PVC привязан к исчезнувшей ноде.
**Blast radius**: 
- Loki: вся история логов потеряна.
- Prometheus: метрики за `retention: 1d` потеряны.
**Detection**: 
- Pod в `Pending` → `FailedScheduling`.
- Grafana: no data.
**Mitigation**:
1. `kubectl describe pvc <name>` — увидеть ошибку.
2. Если под не пересоздан — `kubectl delete pod <loki-0>`.
3. Если PVC «залип» — `kubectl delete pvc` + пересоздание.
**Recovery**:
- Данные **не восстановятся** — это и есть R7.
**Prevention**:
- Loki → S3 backend.
- Prometheus → remote write или Longhorn PVC.
- **Backup в S3** для обоих.
**Owner**: @Aleksandr6077
**Реальный инцидент**: нет, но риск явный.

---

### FM-6: Утечка `sa_key.json`

**Триггер**: файл попал в коммит, либо `make` передал его в env 
и он утёк в логи CI.
**Blast radius**: 
- Злоумышленник может: читать S3 state, читать/менять VPC, 
  останавливать ВМ, читать Object Storage.
**Detection**:
- Gitleaks в CI (сработает только если файл в коммите).
- Yandex Cloud audit log: необычные API-вызовы.
**Mitigation**:
1. Немедленно **revoke** ключ в Yandex Cloud Console.
2. Ротация: создать новый SA-ключ.
3. Проверить audit log на аномалии.
**Recovery**:
- Обновить ключ в CI secrets, в `~/.aws/credentials`, в Makefile env.
**Prevention**:
- **OIDC для CI** — статический ключ не нужен.
- `sa_key.json` в `.gitignore` (есть) + pre-commit hook (есть).
- **Vault / Lockbox** для хранения.
**Owner**: @Aleksandr6077
**Реальный инцидент**: нет.

---

### FM-7: ArgoCD рассинхронизирован (drift)

**Триггер**: кто-то сделал `kubectl edit` руками. Или `Replace: true` 
снёс ресурс, а Git не обновился.
**Blast radius**: 
- Приложение работает, но не воспроизводится.
- Следующий `sync` может **сломать** работающий прод.
**Detection**:
- ArgoCD UI: `OutOfSync`.
- Alert: `argocd_app_info{sync_status="OutOfSync"} == 1`.
**Mitigation**:
1. `argocd app diff <app>` — увидеть расхождение.
2. Решить: **вернуть из Git** (`argocd app sync`) или 
   **зафиксировать в Git** (`kubectl get -o yaml > manifest`).
**Recovery**:
- `selfHeal: true` (у тебя есть) — ArgoCD сам вернёт.
- Но если изменения **легитимные** — надо в Git.
**Prevention**:
- Запрет `kubectl edit` (RBAC + политика).
- `ServerSideApply` вместо `Replace`.
- Pre-commit + CI на изменение манифестов.
**Owner**: @Aleksandr6077
**Реальный инцидент**: да, во время Этапа 12 (Unknown → Synced).

---

### FM-8: Утечка пароля Grafana

**Триггер**: `existingSecret` попал в Git как plaintext (было на Этапе 1).
**Blast radius**: доступ к дашбордам, метрикам, логам.
**Detection**: Gitleaks.
**Mitigation**:
1. Ротация пароля: `kubectl -n monitoring delete secret ...` + пересоздать.
2. Ротация — после этого **все сессии инвалидируются**.
**Recovery**: 2 минуты.
**Prevention**:
- Ansible Vault (есть).
- Для прода — **ESO + Lockbox**.
- `git filter-repo` для очистки истории (если утекло).
**Owner**: @Aleksandr6077
**Реальный инцидент**: да, на Этапе 1 (исправлено).

### FM-9: TBA