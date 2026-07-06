#!/bin/sh
# ttyd wrapper: kubectl exec into the open-design daemon container

NAMESPACE="open-design"
LABEL="app=open-design"
CONTAINER="open-design"

while true; do
  POD=$(kubectl get pod -l "$LABEL" -n "$NAMESPACE" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -n "$POD" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  Open Design Terminal — connected to: $POD"
    echo "║  Type 'exit' to disconnect (auto-reconnects)    ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    kubectl exec -it "$POD" -n "$NAMESPACE" -c "$CONTAINER" -- /bin/bash
    echo ""
    echo "Session ended. Reconnecting in 2s..."
    sleep 2
  else
    echo "Waiting for open-design pod to be ready..."
    sleep 5
  fi
done
