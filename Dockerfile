# ==============================================================================
# ЭТАП 1: Сборка и скачивание зависимостей (Builder)
# ==============================================================================
FROM alpine:3.20 AS builder

# Фиксируем версии утилит
ENV GITLEAKS_VERSION=8.18.2
ENV TRIVY_VERSION=0.51.1
ENV KUBECONFORM_VERSION=0.7.0

# Ставим curl для скачивания релизов
RUN apk add --no-cache curl

# 1. Качаем и распаковываем Gitleaks
RUN curl -L -o gitleaks.tar.gz https://github.com{GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_amd64.tar.gz \
    && tar -xzf gitleaks.tar.gz gitleaks \
    && mv gitleaks /usr/local/bin/

# 2. Качаем и распаковываем Trivy
RUN curl -L -o trivy.tar.gz https://github.com{TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz \
    && tar -xzf trivy.tar.gz trivy \
    && mv trivy /usr/local/bin/

# 3. Качаем и распаковываем Kubeconform
RUN curl -L -o kubeconform.tar.gz https://github.com{KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz \
    && tar -xzf kubeconform.tar.gz kubeconform \
    && mv kubeconform /usr/local/bin/


# ==============================================================================
# ЭТАП 2: Финальный минимальный образ для CI (Runner)
# ==============================================================================
FROM alpine:3.20

# Устанавливаем ТОЛЬКО то, что нужно для запуска тестов в рантайме
# git нужен для gitleaks (сканировать историю), python3/pip — для yamllint
# libc6-compat необходим для корректного запуска go-бинарников в alpine
RUN apk add --no-cache \
    git \
    python3 \
    py3-pip \
    yamllint \
    libc6-compat

# Копируем ИСКЛЮЧИТЕЛЬНО готовые скомпилированные бинарники из первого этапа
COPY --from=builder /usr/local/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=builder /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=builder /usr/local/bin/kubeconform /usr/local/bin/kubeconform

# Быстрый смоук-тест: проверяем, что все скопированные утилиты работают внутри финального слоя
RUN gitleaks version && trivy --version && kubeconform -v && yamllint --version

WORKDIR /workspace
