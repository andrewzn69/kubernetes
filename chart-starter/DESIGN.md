# Helm Chart Starter Template - Design Document

**Date:** 2025-12-13
**Status:** Design Complete
**Purpose:** Standardized helm chart template for homelab Kubernetes infrastructure supporting current NFS setup and future Ceph migration.

---

## Design Principles

1. **Future-proof** - Support multiple backends (NFS → Ceph, SOPS → Infisical/cloud)
2. **Security-first** - Secure defaults, relax only when necessary
3. **Explicit over magic** - No abstractions, clear values
4. **Scalability** - Design for change, avoid hard-coded assumptions
5. **Simple defaults** - Disabled/empty by default, opt-in features

---

## 1. Storage

**Flexibility:** Support NFS (current) and Ceph (future) via `storage.type`.

### Design

```yaml
storage:
  type: nfs  # nfs | ceph
  class: ""  # storageClass for ceph/iscsi

volumes:
  mounts:
    - name: data
      mountPath: /data
      size: 10Gi
      accessMode: ReadWriteMany
      # NFS-specific (ignored if type != nfs)
      nfsServer: "100.64.100.64"
      nfsPath: "/storage/apps/app-name/data"
```

### Templates

**templates/persistentvolume.yaml:**
- Generate only if `storage.type == "nfs"`
- Uses NFS CSI driver
- Manual PV with NFS server/path

**templates/persistentvolumeclaim.yaml:**
- Always generated
- If NFS: binds to manual PV (storageClassName: "")
- If Ceph: uses storageClassName for dynamic provisioning

### Migration Path

```yaml
# Current (NFS)
storage:
  type: nfs

# Future (Ceph)
storage:
  type: ceph
  class: ceph-filesystem
```

---

## 2. Secrets

**Flexibility:** Support SOPS (now), Infisical (future self-hosted), External Secrets (future cloud).

### Design

```yaml
secrets:
  type: sops  # sops | sealed | infisical | external

  # SOPS mode (SOPS-encrypted in git, ArgoCD ksops decrypts)
  sops:
    enabled: true

  # Infisical mode (future)
  infisical:
    enabled: false
    secretsPath: /prod/app-name
    projectId: ""

  # External Secrets mode (AWS/Azure/GCP)
  external:
    enabled: false
    provider: aws
    secretStore: aws-secret-store
    remoteRefs:
      - key: /prod/app/password
        property: password
```

### Templates

**templates/secret.yaml:**
- Conditional based on `secrets.type`
- SOPS: regular Secret (encrypted in git)
- Sealed: SealedSecret CRD (legacy compatibility)
- Infisical: InfisicalSecret CRD
- External: ExternalSecret CRD

### Migration Path

1. **Now:** SOPS + age encryption
2. **Later:** Infisical self-hosted (if want UI)
3. **AWS phase:** External Secrets + AWS Secrets Manager

---

## 3. Ingress

**Access tiers:**
- **Public:** Anyone on internet (Jellyfin) - via Cloudflare Tunnel (manual, outside helm)
- **Private:** VPN-only (Nextcloud, Sonarr, etc.) - via Tailscale ingress

### Design

```yaml
ingress:
  enabled: false
  type: private  # public | private
  host: app.zemn.xyz
  path: /
  pathType: Prefix

  # Public ingress (nginx + TLS)
  public:
    className: nginx
    tls:
      enabled: true
      secretName: ""  # Empty = cert-manager generates
      clusterIssuer: letsencrypt-prod
    annotations: {}

  # Private ingress (tailscale)
  private:
    className: tailscale
    annotations: {}
```

### Templates

**templates/ingress.yaml:**
- Conditional on `ingress.type`
- Public: nginx with cert-manager TLS
- Private: tailscale (handles TLS automatically)

### Notes

- CF Tunnels used for public apps (Jellyfin) but managed outside helm charts
- Tailscale Funnel rejected (forces .ts.net domain, can't use custom)
- Tailscale ingress for private = requires VPN connection (WiFi-only on mobile)

---

## 4. ConfigMaps & Environment Variables

**Support both config files and env vars.**

### Design

```yaml
# Simple env vars (hardcoded)
env:
  - name: PORT
    value: "8080"

# Env vars from ConfigMap (many settings)
envConfigMap:
  enabled: false
  data:
    DATABASE_URL: "postgres://..."
    LOG_LEVEL: "info"

# Config files from ConfigMap
configMap:
  enabled: false
  mountPath: /config
  files:
    app.conf: |
      [server]
      port = 8080
```

### Templates

**templates/configmap.yaml:**
- Two ConfigMaps if both enabled:
  - `app-name-files` (mounted as files)
  - `app-name-env` (injected as env vars)

**templates/deployment.yaml:**
- `env:` from values
- `envFrom:` configMapRef if envConfigMap.enabled
- volumeMounts if configMap.enabled

### Use Cases

- Simple apps: just `env`
- Many settings: `envConfigMap` (change without helm upgrade)
- Config file apps: `configMap.files` (Terraria, Grafana)

---

## 5. Service & Multiple Ports

**Support single port (most apps) and multiple ports (games, metrics).**

### Design

```yaml
service:
  type: ClusterIP  # ClusterIP | NodePort | LoadBalancer
  port: 8080
  targetPort: 8080
  protocol: TCP
  name: http

  # Optional additional ports
  additionalPorts: []
    # - name: metrics
    #   port: 9090
    #   targetPort: 9090
    #   protocol: TCP
    # - name: rcon
    #   port: 25575
    #   targetPort: 25575
    #   nodePort: 30575  # For NodePort type
```

### Templates

**templates/service.yaml:**
- Primary port always included
- Additional ports via range loop
- NodePort only when service.type allows

### Use Cases

- Web apps: single port
- Games: main + RCON ports
- Metrics: app + metrics port

---

## 6. InitContainers

**Common helpers + custom support.**

### Design

```yaml
initContainers:
  # Helper: Fix NFS permission issues
  fixPermissions:
    enabled: false
    volumeName: data
    path: /data
    uid: 1000
    gid: 1000

  # Helper: Wait for database/service
  waitForService:
    enabled: false
    host: postgres
    port: 5432
    timeout: 300

  # Helper: Database migration
  dbMigration:
    enabled: false
    image: ""  # Defaults to main app image
    command: []

  # Custom initContainers (full control)
  custom: []
```

### Templates

**templates/deployment.yaml:**
- Generates initContainers based on helpers
- Appends custom initContainers from array

### Use Cases

- Nextcloud: fixPermissions (UID 33)
- Apps with PostgreSQL: waitForService
- Migration-heavy apps: dbMigration
- Special cases: custom array

---

## 7. Health Probes

**All probe types, all methods, disabled by default.**

### Design

```yaml
probes:
  liveness:
    enabled: false
    type: httpGet  # httpGet | tcpSocket | exec
    httpGet:
      path: /health
      port: http
      scheme: HTTP
    tcpSocket:
      port: 8080
    exec:
      command: []
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    successThreshold: 1
    failureThreshold: 3

  readiness:
    enabled: false
    # same structure

  startup:
    enabled: false
    # same structure
```

### Templates

**templates/deployment.yaml:**
- Conditional generation based on probe.enabled
- Type-specific probe config (httpGet/tcpSocket/exec)

### Use Cases

- Web apps: httpGet on /health
- Databases: tcpSocket
- Game servers: exec with mc-monitor
- Slow starters: startup probe

---

## 8. Metrics

**Prometheus/VMAgent annotations + sidecar exporters.**

### Design

```yaml
metrics:
  enabled: false
  port: 9090
  path: /metrics

  # Prometheus/VMAgent service annotations
  serviceAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
    prometheus.io/path: "/metrics"

  # Sidecar exporter (exportarr pattern)
  sidecar:
    enabled: false
    image: ""
    port: 9707
    env: []
```

### Templates

**templates/service.yaml:**
- Add annotations if metrics.enabled
- Add metrics port to service

**templates/deployment.yaml:**
- Add sidecar container if metrics.sidecar.enabled

### Use Cases

- Native metrics: just enable, set port/path
- Exportarr (Sonarr/Radarr): sidecar with API key env

### Notes

- VMAgent uses service annotations for auto-discovery
- ServiceMonitor CRD not deployed (using standalone VictoriaMetrics)

---

## 9. Resources

**Explicit numbers, no abstractions.**

### Design

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

### Templates

```yaml
{{- with .Values.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
```

### Philosophy

No "small/medium/large" profiles. Explicit values per-app.

---

## 10. Security Contexts

**Secure by default (UID 1000 for NFS compatibility), override when broken.**

### Design

```yaml
# Pod-level
podSecurityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

# Container-level
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false
  capabilities:
    drop:
      - ALL
    add: []
```

### Templates

Both applied in deployment template.

### Override Examples

```yaml
# Nextcloud (www-data)
podSecurityContext:
  runAsUser: 33
  runAsGroup: 33
  fsGroup: 33

# Privileged app
podSecurityContext:
  runAsUser: 0
  runAsNonRoot: false
securityContext:
  allowPrivilegeEscalation: true
```

---

## 11. Labels & Annotations

**Kubernetes recommended labels + custom flexibility.**

### Design

```yaml
nameOverride: ""
fullnameOverride: ""
component: ""      # server, exporter
partOf: ""         # media-stack, productivity
commonLabels: {}
commonAnnotations: {}
```

### Helpers (_helpers.tpl)

```yaml
app.kubernetes.io/name
app.kubernetes.io/instance
app.kubernetes.io/version
app.kubernetes.io/component  # if set
app.kubernetes.io/part-of    # if set
app.kubernetes.io/managed-by: Helm
helm.sh/chart
```

### Use Cases

```yaml
# Jellyfin
partOf: media-stack
component: server

# Nextcloud
partOf: productivity
commonLabels:
  backup: critical
```

---

## 12. Node Selector / Affinity

**Target pods to specific clusters/nodes. Empty by default.**

### Design

```yaml
nodeSelector: {}
  # cluster: vizima
  # storage: nfs

affinity: {}
tolerations: []
```

### Templates

Simple toYaml passthrough in deployment.

### Future Usage

After labeling nodes:
```yaml
# Jellyfin (needs NFS)
nodeSelector:
  cluster: vizima
  storage: nfs

# Terraria (Oracle for latency)
nodeSelector:
  cluster: novigrad
```

---

## 13. Replica Count

**Simple, always included.**

### Design

```yaml
replicaCount: 1
```

### Templates

```yaml
spec:
  replicas: {{ .Values.replicaCount }}
```

---

## Not Included

**Deliberately excluded (add later if needed):**

- PodDisruptionBudget (all apps single replica)
- HorizontalPodAutoscaler (not needed)
- NetworkPolicy (security hardening later)
- ServiceAccount (most apps don't need RBAC)
- PriorityClass (not needed)
- Image pull secrets (using public registries)

---

## File Structure

```
chart-starter/
├── Chart.yaml
├── .helmignore
├── values.yaml
├── DESIGN.md (this file)
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── service.yaml
    ├── persistentvolume.yaml
    ├── persistentvolumeclaim.yaml
    ├── ingress.yaml
    ├── secret.yaml
    ├── configmap.yaml
    └── NOTES.txt
```

---

## Usage

```bash
# Create new chart
helm create mychart --starter chart-starter

# Customize values.yaml
vim mychart/values.yaml

# Deploy via ArgoCD
kubectl apply -f apps/mychart.yaml
```

---

## Migration Timelines

**Storage:**
- Now: NFS (`storage.type: nfs`)
- ~2025-01-02: Buy enclosure + disk
- Week 1: Deploy Rook-Ceph
- Week 2-4: Migrate apps to Ceph (`storage.type: ceph`)

**Secrets:**
- Now: SOPS + age (`secrets.type: sops`)
- 6+ months: Evaluate Infisical if UI needed
- AWS phase: External Secrets + AWS Secrets Manager

**Ingress:**
- Now: CF Tunnels (public) + Tailscale (private)
- Future: Monitor Tailscale Funnel for custom domain support
- AWS phase: ALB + Cognito

---

## References

- Project planning: `/home/zemn/Development/knowledge/projects/helm-chart-standardization.md`
- Storage migration: `/home/zemn/Development/knowledge/projects/storage-migration-ceph.md`
- Session journal: Will be created at session end
