#!/bin/bash

set -e

# Ask the user to give a name for the cluster with a default of 'grafana'
read -p "Please enter a name for the cluster (default: grafana): " cluster_name
cluster_name=${cluster_name:-grafana}

# Check if the cluster exists
if minikube status -p "$cluster_name" | grep -q "Running"; then
    echo "Cluster already exists."
else
    # Start Minikube
    minikube start -p "$cluster_name" --memory 4000
fi

# set context to cluster
kubectl config use-context "$cluster_name"

# Ask the user if they would like to add Helm repositories
read -p "Would you like to add Helm repositories? (default: No) " add_repos
add_repos=${add_repos:-n}

if [[ "$add_repos" =~ ^[Yy]$ ]]; then
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add vector https://helm.vector.dev
    helm repo update &> /dev/null;
else
    echo "Skipping adding Helm repositories."
fi

# Create namespaces
NAMESPACES=(observability metrics logs tracing)

for namespace in "${NAMESPACES[@]}"; do
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        kubectl create namespace "$namespace"
    else
        echo "Namespace $namespace already exists."
    fi
done

# Install Prometheus CRDs
if helm status prometheus-crds -n metrics &> /dev/null; then
    echo "Prometheus CRDs already installed."
else
    echo "Installing Prometheus CRDs..."
    helm install -n metrics prometheus-crds prometheus-community/prometheus-operator-crds &> /dev/null
fi

# Install Prometheus
if helm status prometheus -n metrics &> /dev/null; then
    echo "Prometheus already installed."
else
    echo "Installing Prometheus..."
    helm install -n metrics prometheus prometheus-community/prometheus &> /dev/null
fi

# Install Grafana
if helm status grafana -n observability &> /dev/null; then
    echo "Grafana already installed."
else
    echo "Installing Grafana..."
    helm install -n observability grafana grafana/grafana -f grafana-values.yaml &> /dev/null
fi

# Install Tempo and OpenTelemetry Collector
if helm status tempo -n tracing &> /dev/null; then
    echo "Tempo already installed."
else
    echo "Installing Tempo..."
    helm install -n tracing tempo grafana/tempo -f tempo-values.yaml &> /dev/null
fi

if helm status opentelemetry-collector -n tracing &> /dev/null; then
    echo "OpenTelemetry Collector already installed."
else
    echo "Installing OpenTelemetry Collector..."
    helm install -n tracing opentelemetry-collector open-telemetry/opentelemetry-collector -f otel-values.yaml &> /dev/null
fi

# Install Loki
if helm status loki -n logs &> /dev/null; then
    echo "Loki already installed."
else
    echo "Installing Loki..."
    helm install -n logs loki grafana/loki -f loki-values.yaml &> /dev/null
fi

# Wait for Loki to be ready
echo "Waiting for Loki to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n logs --timeout=300s

# Install Vector
if helm status vector -n logs &> /dev/null; then
    echo "Vector already installed."
else
    echo "Installing Vector..."
    helm install -n logs vector vector/vector -f vector-values.yaml &> /dev/null
fi

# Apply Tests
echo "Applying Tests..."
kubectl apply -n logs -f loki-test.yaml
kubectl apply -n tracing -f trace-test.yaml

echo "Installation complete!"