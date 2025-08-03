#!/bin/bash

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd ./charts/argocd --namespace argocd --create-namespace
kubectl apply -f apps/argocd.yaml
