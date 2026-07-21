# Argo CD（Stage 2 W6）

## 安装

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
```

## 登录

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
-o jsonpath="{.data.password}" | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  user=admin
```

## 业务 Application

见同目录 \`application-iot-learn-lab.yaml\`。  
**先 push Chart 到 Git，再 apply Application。**  
从 Helm CLI 迁权：先 \`helm uninstall iot-learn -n iot-learn\`，再 Sync。