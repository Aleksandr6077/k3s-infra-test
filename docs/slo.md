# SLO: k3s-infra-test

> Этот документ — не «мы хотим быть надёжными». Это **контракт с самим собой**:
> какие цифры мы обещаем, чем платим за их нарушение, и что считаем принятым риском.
> Без цифр любая HA — это вера, а не инженерия.
> Цифры беру примерные, считать нужно будет на реальных кейсах.

## 1. Контекст

| Параметр | Значение |
|---|---|
| Стенд | k3s multi-zonal HA, Yandex Cloud |
| Топология | 3 master (a/b/d), 2 worker (a/b), bastion (b) |
| Режим ВМ | preemptible = true |
| Storage | Longhorn, 2 реплики |
| Ingress | Yandex NLB (80/443) → Traefik NodePort (masters) |
| Назначение | side-проект / демонстрация архитектуры |

**Явное ограничение**: стенд не обслуживает реальных пользователей.
SLO ниже — целевые, не контрактные. Они отражают **что мы бы обещали**, 
если бы продавали этот сервис.

## 2. SLI (что измеряем)

| SLI | Формула | Источник |
|---|---|---|
| Availability API | `1 - (5xx / total) за 30d` | Prometheus, `apiserver_request_total` |
| Latency API p99 | `histogram_quantile(0.99, ...)` | Prometheus, `apiserver_request_duration_seconds` |
| Availability Ingress | `1 - (5xx / total) на NLB` | Yandex Monitoring, NLB metrics |
| Success rate GitOps | `synced / total` от ArgoCD | `argocd_app_sync_total` |
| Loki ingestion | `bytes_received / expected` | Loki internal metrics |

## 3. SLO (что обещаем)

| SLI | Целевой SLO | Период | Error budget |
|---|---|---|---|
| Availability API (kubectl) | **99.5%** | 30d | 3h 39m |
| Latency API p99 | **< 1s** | 30d | — |
| Availability Ingress (HTTP) | **99.0%** | 30d | 7h 18m |
| GitOps sync success | **99.9%** | 30d | 43m |
| Восстановление после падения 1 ноды | **< 15m** | per-incident | — |

**Почему 99.5%, а не 99.9%**: preemptible + embedded etcd на 2 vCPU 
физически не дадут 99.9%, никак.

## 4. Error budget policy

Когда **месяц израсходован на 50%**:
- Замораживаются фичи.
- Команда переключается на reliability-работу.

Когда **израсходован на 100%**:
- Все изменения — только через canary.
- Обязательный post-mortem по каждому инциденту.

Для side-проекта это правило «на бумаге» — оно демонстрирует мышление, 
но не применяется буквально.

## 5. Принятые риски (явно)

Это **не баги**. Это решения, за которые мы осознанно платим.

| # | Риск | Причина | Влияние | RTO | RPO |
|---|---|---|---|---|---|
| R1 | Preemption 1 master | экономия 70% | деградация API, etcd без кворума | 5–10 мин | 0 |
| R2 | Preemption 2 master одновременно | экономия | **кластер мёртв** | 30+ мин | возможна потеря последних мутаций |
| R3 | Отказ зоны `ru-central1-a` | — | -1 master, -1 worker, потеря 1 реплики Longhorn | 5 мин | 0 |
| R4 | Отказ зон `a` + `d` | — | потеря 2 master → **кластер мёртв** | часы | возможна потеря |
| R5 | Bastion preempted в момент деплоя | экономия | деплой падает | 5 мин | 0 |
| R6 | Loki SingleBinary down | упрощение | потеря свежих логов | до 10 мин | до 1ч (retention) |
| R7 | Потеря PVC `local-path` (Loki/Prometheus) | упрощение | потеря истории | пересоздание | вся история |

**Мы допускаем R1–R7, потому что эфемерный 
стенд и SLA отсутствует. Для прода R1, R2, R5, R7 закрываются переходом 
на non-preemptible + Longhorn 3 реплики + S3 для observability.**

## 6. RTO / RPO (по компонентам)

| Компонент | RTO | RPO | Чем обеспечивается |
|---|---|---|---|
| Kubernetes API | 15 мин | 0 | 3 master, etcd quorum |
| etcd state | 15 мин | 0 (in-memory) / 5 мин (snapshot) | встроенные snapshot'ы k3s |
| Приложение (Nginx) | 2 мин | 0 | RWO PVC, 1 replica |
| Longhorn volume | 10 мин | 0 | 2 реплики |
| Loki логи | 10 мин | до 1ч | local-path, SingleBinary |
| Prometheus метрики | 10 мин | до 1d | retention=1d, local-path |

## 7. Что НЕ покрыто

- ‼️‼️ **Multi-region**: нет. Отказ региона — полный даунтайм.
- ‼️‼️ **Бэкапы etcd**: `snapshot`'ы есть, `restore drill` не проводился.
- ‼️‼️ **Chaos engineering**: только `manual preemption test`.
- ‼️‼️ **DDoS**: `NLB` не имеет защиты.
- ‼️‼️ **Compliance**: 152-ФЗ / PCI / SOC2 — не применимо.

## 8. Пересмотр

Документ пересматривается:
- При изменении архитектуры (например, переход на managed K8s).